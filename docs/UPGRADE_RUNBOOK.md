# EBS 12.2 → Oracle AI Database 26ai Upgrade Runbook (19c source → 26ai)

> **Purpose**: Reproduce the working 26ai EBS environment from a fresh 19c copy of the app + DB
> tiers, autonomously where possible, and **avoid the credential/verifier dead-end** that blocked
> ISG REST on the current clone.
> **Scope**: Single-node EBS 12.2 on Oracle Linux, CDB/PDB multitenant, on-prem/ODB@AWS style.
> **Execution model**: I (agent) drive deterministic stages over SSM. A small number of
> **interactive gates** (DB AutoUpgrade, password prompts) are answered live to avoid the
> non-interactive hangs we hit with adop/txk.

## Target architecture

![EBS Finance Assistant architecture topology (Oracle 26ai) — two-VPC (ODB@AWS peering)](architecture-26ai-topology.png)

The end state this runbook reproduces: a two-VPC topology where the **Application / AI VPC** (agent + Lambdas + SQLcl MCP) peers over the **ODB@AWS network** to the **EBS / Oracle VPC** (ODB Network) holding the upgraded Oracle 26ai DB and the EBS 12.2 app tier in private subnets.

## ⚠️ READ FIRST — THE ROOT CAUSE WE MUST NOT REPEAT

**What broke the current 26ai clone (write-back / ISG REST = HTTP 500):**
The EBS app tier could not open its runtime APPS connection — `ORA-01017` in
`AppsConnectionManager.makeGuestConnection` — because the **FND credential store
(`fnd_oracle_userid`) and the APPS/APPLSYSPUB password verifiers got out of sync during the
19c→26ai upgrade.** Specifically:

| Symptom | Evidence |
|---|---|
| ISG `provider/isActive` and all REST → HTTP 500 | oafm diag: `makeGuestConnection → ORA-01017` |
| DB audit shows failing user = **APPS** from app host | `dba_audit_trail returncode=1017` |
| FNDCPASS + AFPASSWD both fail | `Error in password verification for APPS` (every mode) |
| `sqlplus apps/apps` works, but FND verify path fails | raw DB login OK; FND signon/verify broken |
| 19c source vs 26ai clone password_versions | **APPLSYSPUB/APPLSYS lost `10G` verifier**; 19c had `10G 11G`, 26ai had `11G 12C` |
| Case-sensitivity | 19c `SEC_CASE_SENSITIVE_LOGON=FALSE`; 26ai forces TRUE (param **desupported** in 23ai — `alter system set` → ORA-02065) |

**Why it became unrecoverable in place:** adop (apply AND cleanup) needs a working APPS
connection → blocked. FNDCPASS (the tool that re-encrypts `fnd_oracle_userid`) fails its own APPS
verification → blocked. Circular. `txkPostPDBCreationTasks.pl` validated DB-side creds and
recompiled the EBS_LOGON trigger but did **not** re-encrypt the FND credential store, so the
runtime APPS connection still failed. There is no in-place escape on 23ai because the 10G verifier
cannot be regenerated and case-sensitivity cannot be relaxed.

### 🎯 THE PREVENTION STEP (KA1151 Section 2 — "Enable case-sensitive passwords")
This is the single most important step and the one that was mishandled. **Do it correctly, in
order, on the 19c source BEFORE the database upgrade:**

1. If `SEC_CASE_SENSITIVE_LOGON=FALSE` on the 19c source, **enable case-sensitive passwords** per
   *Using Case-Sensitive Database Passwords* (EBS Maintenance Guide 12.2) — this regenerates the
   modern (11G/12C) verifiers for the EBS schemas **while still on 19c**, the EBS-managed way.
2. Then follow *Important Additional Instructions to Update WLS Data Source* (EBS Maintenance Guide
   12.2): start ONLY the WLS AdminServer and **modify the APPS password in the WLS data source**.
3. **Also modify the APPLSYSPUB password the EBS-managed way** (FNDCPASS / the documented WLS
   step) — NOT a bare `ALTER USER APPLSYSPUB IDENTIFIED BY ...`. A bare ALTER USER changes the DB
   account but leaves `fnd_oracle_userid` encrypted under the old key → exactly our failure.

> **GOLDEN RULE:** Never change APPS / APPLSYS / APPLSYSPUB / SYSTEM with `ALTER USER` directly.
> Always use **FNDCPASS** (or AFPASSWD) so the DB account, `fnd_oracle_userid`, `fnd_vault`, and the
> WLS data source stay in lockstep. Mixing `ALTER USER` with EBS-managed creds is what desynced the
> verifier chain.

### ✅ EARLY-DETECTION GATES (run these to catch the problem before it's baked in)
Add these checkpoints to the upgrade; STOP and fix if any fails:

- **GATE A (pre-upgrade, on 19c):** confirm `SEC_CASE_SENSITIVE_LOGON` and verifiers, and that the
  case-sensitive-password + WLS-datasource + APPLSYSPUB steps were completed:
  ```sql
  ALTER SESSION SET CONTAINER=<PDB>;
  SELECT username, password_versions FROM dba_users
   WHERE username IN ('APPS','APPLSYS','APPLSYSPUB','SYSTEM','GUEST');
  SHOW PARAMETER sec_case_sensitive_logon
  ```
  Expect APPS/APPLSYS/APPLSYSPUB to carry the verifier set EBS expects post-step (11G/12C present).
  Record the values — you will re-check after the upgrade.
- **GATE B (immediately after DB upgrade, before app-tier work):** re-run the same query. If
  APPLSYSPUB/APPLSYS verifiers changed vs Gate A in a way that drops what EBS needs, **fix now** via
  FNDCPASS while adop still works — do NOT proceed.
- **GATE C (after txkPostPDBCreationTasks + app AutoConfig, before declaring done):** the live
  acceptance test — must pass:
  ```bash
  # APPS verification via the FND path (the thing that was broken):
  FNDCPASS apps/apps 0 Y system/<pw> SYSTEM APPLSYS apps   # must NOT say "Error in password verification for APPS"
  # runtime proof:
  curl -s -o /dev/null -w '%{http_code}\n' http://<apphost>:8000/webservices/rest/provider/isActive/   # expect 200, body ACTIVE
  # DB audit must show NO new APPS returncode=1017 after hitting isActive
  ```
  If FNDCPASS errors or isActive ≠ 200, you are reproducing the dead-end — stop and fix the
  credential chain (Gate A step) rather than pressing on.

---

## Environment / Inputs (fill at run time)

| Item | Value |
|---|---|
| AWS account / region | 339712993582 / us-east-1 (default creds, NO --profile) |
| Fresh 19c APP node | `i-0ad92190221d3b6c2` (ERP-R122-SOGW-APP) |
| Fresh 19c DB node | `i-0cd2f987c6efef853` (ERP-R122-SOAGW-db) |
| CDB / PDB | CERPUAT / ERPUAT |
| 19c ORACLE_HOME | /fd01/ERPUAT/19.0.0 |
| 26ai ORACLE_HOME (new, separate dir) | /fd01/ERPUAT/23.0.0 |
| EBS env (app) | /fh01/ERPUAT/EBSapps.env |
| Passwords | Environment-specific — set at deploy, stored in AWS Secrets Manager (never commit). EBS schema passwords must be set EBS-managed via FNDCPASS only — never bare ALTER USER. |
| Patch S3 staging | s3://26aipatches-339712993582/ |
| Access | SSM Session Manager + AWS-RunShellScript |

> **Interactive-gate note:** adop, txkPostPDBCreationTasks.pl, AFPASSWD, AutoUpgrade and password
> prompts must be answered in a real shell (SSM Session Manager). Driving them via non-interactive
> `AWS-RunShellScript` heredocs caused multi-minute hangs (adzdoptl.pl spinning) and failed creds.
> Everything else (file staging, ETCC, AutoConfig wrappers, ORDS/APEX install, SELECT AI/vector) is
> safe to automate.

---

## Reference MOS notes (the runbook source of truth)

| Doc | Title | Used for |
|---|---|---|
| KA1151 / 2962871.1 | Interoperability Notes: EBS 12.2 with Oracle AI Database 26ai | Pre-upgrade tasks (incl. the case-sensitive password step) |
| KA1452 | Upgrading EBS 12.2 (19c → 26ai) Single Node | Software install + AutoUpgrade + post-upgrade |
| KA1054 / 1617461.1 | Applying latest AD & TXK RUPs (Delta 17) | AD/TXK Delta 17 (Path A new install / Path B existing) |
| KB556816 | Applying R12.ATG_PF.C.Delta.11 RUP | ATG_PF Delta 11 prerequisite |
| KA989 / 1594274.1 | Consolidated DB Patches + ETCC | ETCC + required DB bugfixes |
| KA1055 / 1311068.1 section 11 | ISG post-DB-upgrade tasks | ISG REST validate/redeploy after upgrade |
| KA1002 / 396009.1 | DB init parameters for EBS 12 | init.ora during/after AutoUpgrade |

---

## Stage 0 — Pre-flight & baseline (automatable)
1. Verify SSM reachability to both fresh 19c nodes; record IDs, homes, SIDs.
2. Snapshot/clone-safety: confirm these are the throwaway 19c copies (the original 19c source must
   remain untouched).
3. Capture baseline: EBS release, AD/TXK/ATG_PF codelevels, DB version, `password_versions`,
   `SEC_CASE_SENSITIVE_LOGON`, ISG status. Save to PROGRESS.

## Stage 1 — EBS prerequisite patches (KA1151 section 2 + KA1054 + KB556816) (mostly automatable; adop gates interactive)

> **⚠️ ALL PATCHES IN DOWNTIME MODE.** Use `adop phase=apply apply_mode=downtime patches=...`
> exclusively (no hotpatch, no online prepare/cutover). Sequence: `adstpall.sh` → apply every patch
> in downtime mode → AutoConfig → `adstrtal.sh`. Prompts via stdin: APPS / EBS_SYSTEM / WLSADMIN
> passwords (environment-specific). The clone has no live users so downtime is free and avoids online-patching
> session bookkeeping (the deadlock that bit the original box).

> **⚠️ SKIP-JOB RULE for missing column/table:** If a worker fails applying SQL to a NON-CRITICAL
> table because a column/object is missing (ORA-00904 / ORA-00942) — a clone/upgrade artifact — use
> `adctrl` option **8** (hidden "skip failed job") to mark that job complete and let the patch
> finish. Log every skip in PROGRESS.md (patch#, file, table, reason). Do NOT skip core AD/FND
> bootstrap (adgrants etc.) — fix at root.
> **DB-tier prerequisite for 12.2.11 (EBS_SYSTEM model):** before adop prereq patches, run
> `adgrants.sql <APPS>` as **SYS on the DB tier** (in the PDB) to seed SYS→EBS_SYSTEM grants;
> otherwise the in-patch adgrants worker fails ("Invalid apps schema").

Target codelevels for 26ai interop: **AD ≥ Delta 16/17, TXK ≥ Delta 16/17, ATG_PF ≥ Delta 11**, plus
the 26ai interop patch set. (Our clone was AD/TXK C.17, ATG_PF C.11 — good.)
1. Run **ETCC** (`checkDBpatch.sh` on DB, `checkMTpatch.sh` on app) — latest via Patch 17537119.
   Apply any missing DB/MT bugfixes (KA989). **ETCC must record results for the running DB home or
   adop blocks every phase** (we hit "ETCC not run").
2. Apply AD/TXK Delta 17 (Patch 37197085 + 37204510) per KA1054 Path B (existing) — adop hotpatch /
   prepare→apply→finalize→cutover→cleanup→fs_clone. **Interactive (passwords).**
3. Apply ATG_PF Delta 11 (Patch 33527666 + merge 36842768) per KB556816 if not already present.
4. Apply the KA1151 section 2 interop patch list (24690690, 35876968, 31669299, 36960053, 37012872,
   37288906/37323421 for ISG, 38310802, 38633086, etc. — apply only those that match the install).
5. Run AutoConfig (app + DB) after the RUPs.

## Stage 2 — KA1151 section 2 PRE-UPGRADE TASKS (THE CRITICAL ONES) (interactive)
Run on the **19c source PDB** before touching the DB binaries:
1. `hcheck.sql` (KB150043) — fix data dictionary issues.
2. **EBS System Schema migration** (KB837303) if not already done.
3. **★ Enable case-sensitive passwords (GATE A) ★** — the prevention step (see top of doc):
   - Enable case-sensitive passwords (regenerates modern verifiers EBS-managed) while on 19c.
   - Update the **WLS data source** APPS password (AdminServer-only procedure).
   - Update **APPLSYSPUB** password the EBS-managed way (FNDCPASS), never bare ALTER USER.
   - Record `password_versions` for APPS/APPLSYS/APPLSYSPUB/SYSTEM/GUEST.
4. (Conditional) Ensure **uppercase PDB name** (KA1149) — only uppercase PDB names supported on 26ai.
5. (Conditional) TDE init params if encrypted.
6. Remove old online-patching editions: `ADZDSHOWED.sql`; if >10 editions actualize_all→cutover→
   full cleanup→`ADZDRUNCLEANUNUSE.sql`; else cutover→full cleanup. End with **1 edition**.

## Stage 3 — Install 26ai software + DB patches (KA1452 section 3) (automatable + interactive installer)
1. Install 26ai EE (23.26.x) into a **separate** ORACLE_HOME (`/fd01/ERPUAT/23.0.0`), software-only.
2. Set ORACLE_BASE/HOME/PATH/LD_LIBRARY_PATH/PERL5LIB to the new home.
3. Apply 26ai DB patches (KA989 26ai table). Patch perl if needed; re-verify PERL5LIB.
4. `perl $ORACLE_HOME/nls/data/old/cr9idata.pl` → create `nls/data/9idata`; set `ORA_NLS10`.

> **★ MANDATORY: cr9idata.pl ★** If `$ORACLE_HOME/nls/data/9idata` is missing, the DB **open
> aborts with ORA-41400 "Bind character set does not match database character set"** and the
> instance terminates (we hit this). Always run `perl $ORACLE_HOME/nls/data/old/cr9idata.pl` and
> export `ORA_NLS10=$ORACLE_HOME/nls/data/9idata` + `NLS_LANG=AMERICAN_AMERICA.<charset>` before any
> startup/open of the upgraded DB. Put ORA_NLS10 in the oracle login env (init<rel>_cdb.env) so the
> listener's forked dedicated servers inherit it (else TNS connects fail ORA-28547).
> **Also:** create the new home's password file (`orapwd file=$OH/dbs/orapw<CDB> password=<sys_pw>
> format=12`) — on hosts where the oracle uid breaks OS auth (`/ as sysdba` → ORA-01005), connect
> with `sys/<pw> as sysdba`. After a forced kill, clear stale IPC (`ipcrm`) + /dev/shm or startup
> fails ORA-28547.

## Stage 4 — Pre-upgrade config (KA1452 section 4) (automatable)
1. `admkappsutil.pl` → appsutil.zip → copy to DB tier → unzip in 26ai home.
2. Create CDB TNS files: `txkSetCfgCDB.env` + `txkGenCDBTnsAdmin.pl`.
   **Verify new `sqlnet.ora` contains `SQLNET.ALLOWED_LOGON_VERSION_SERVER=12`** (KA1452 explicitly
   requires this — and note it is 12, which is why old thin clients/verifiers matter; tie this back
   to GATE A so APPS/APPLSYSPUB verifiers are ≥11G).
3. Update UTL_FILE_DIR directory objects (KA987).

## Stage 5 — DB upgrade via AutoUpgrade (KA1452 section 5) (INTERACTIVE GATE — highest risk)
1. Shut down app-tier services; shut down 19c listener; unset LOCAL_LISTENER; disable DB Vault if used.
2. Build AutoUpgrade config (source_home=19.0.0, target_home=23.0.0, pdbs=ERPUAT, run_utlrp=yes,
   timezone_upg=yes, target_version=23). Create add/del during/after pfiles per KA1002. **Delete
   `sec_case_sensitive_logon`, `utl_file_dir`, `user_dump_dest`, `db_cache_size`, `undo_retention`
   in the del pfiles** (per KA1452 example).
3. `java -jar autoupgrade.jar -config ... -mode analyze` → fix → `-mode fixups` → `-mode deploy`.
4. Set `compatible` after testing; restart DB.
5. **★ GATE B ★** — re-run the `password_versions` + case-sensitivity query. Compare to Gate A.
   If APPLSYSPUB/APPLSYS verifiers regressed (e.g. lost a verifier EBS needs) **fix via FNDCPASS now**
   while the DB is healthy and adop still works. Do not continue with a desynced credential chain.

## Stage 6 — Post-upgrade DB + app config (KA1452 section 6) (mix; txk + AutoConfig)
1. Start 26ai listeners (`txkGenPDBTnsAdmin.pl`, `lsnrctl start <CDB>`).

> **★ UPDATE oracle .bash_profile for the 26ai home (do right after the upgrade) ★**
> The 19c clone's `~oracle/.bash_profile` sources `~/init19c_cdb.env`. After the upgrade, create the
> 26ai equivalent so login shells auto-load the new home (matches the steering "env auto-load" rule):
> ```bash
> # ~oracle/init26ai_cdb.env  (mirror of init19c_cdb.env, new home)
> export ORACLE_BASE=/fd01/ERPUAT
> export ORACLE_HOME=/fd01/ERPUAT/23.0.0
> export PATH=$ORACLE_HOME/bin:$ORACLE_HOME/perl/bin:$ORACLE_HOME/OPatch:$PATH
> export LD_LIBRARY_PATH=$ORACLE_HOME/lib
> export TNS_ADMIN=$ORACLE_HOME/network/admin
> export PERL5LIB=$ORACLE_HOME/perl/lib/<ver>:$ORACLE_HOME/perl/lib/site_perl/<ver>
> export ORA_NLS10=$ORACLE_HOME/nls/data/9idata
> export ORACLE_SID=CERPUAT
> ```
> Then edit `~oracle/.bash_profile` to `. init26ai_cdb.env` (was `. init19c_cdb.env`). Verify the
> PERL5LIB perl version dir under the new home; keep ORACLE_SID=CERPUAT and TNS_ADMIN consistent.

2. Grant DB privileges: `adrevoke.sql` then KA1057 Option 2 grants.
3. Compile invalids: `catcon.pl ... utlrp.sql`.
4. Gather SYS stats: `adstats.sql` (restricted session).
5. **`txkPostPDBCreationTasks.pl`** (interactive) — regenerates DB context + AutoConfig, validates
   APPS/SYSTEM/EBS_SYSTEM, **recompiles EBS_LOGON trigger**, runs ADGrants.
   - Inputs we used: dboraclehome=/fd01/ERPUAT/23.0.0, CDB=CERPUAT, PDB=ERPUAT,
     out=/fd01/ERPUAT/23.0.0/appsutil/out, apps/system/ebs_system pw.
   - ⚠️ This does **not** re-encrypt `fnd_oracle_userid`; it is necessary but **not sufficient** to
     fix a verifier desync — Gate A is what prevents that.
6. Run AutoConfig on **all app tiers** (patch + run). Update context: new DB port,
   `s_apps_jdbc_connect_descriptor`=NULL, `s_applptmp` to a UTL_FILE_DIR dir.
7. Network ACLs (KA1193). ETCC on DB (KA989). EDBPC param check (KA1180).
8. Regenerate JARs (adadmin). Restart app tier (`adstrtal.sh`).
9. **★ GATE C ★** — acceptance test (FNDCPASS clean + isActive 200 + no APPS 1017 in audit).

> **★ MANDATORY for 26ai AI features: raise COMPATIBLE + clear the FRA ★** (we hit both)
> After Gate C, before building the AI layer:
> 1. **COMPATIBLE is left at 19.0.0 by AutoUpgrade** (one-way bump, done manually after validation).
>    The **VECTOR datatype is DISABLED** until raised → `ORA-00406 "COMPATIBLE needs to be 20.0 or
>    greater"` when creating any VECTOR table / loading an ONNX model. Fix (gold AMI is the restore
>    point — take it first):
>    ```sql
>    alter system set compatible='23.26.0' scope=spfile;
>    alter system set vector_memory_size=512M scope=spfile;   -- HNSW/vector pool
>    -- restart CDB+PDB (shutdown immediate; startup; alter pluggable database <PDB> open;)
>    ```
> 2. **FRA fills with the AutoUpgrade archivelogs.** The upgrade runs in ARCHIVELOG; afterwards the
>    clone is NOARCHIVELOG but hundreds of archivelogs remain, filling `db_recovery_file_dest_size`
>    to ~100% → `ORA-19815`, which **stalls heavy DBMS_VECTOR / DBMS_CLOUD_AI ops and ONNX loads**
>    (the session appears to hang). Reclaim with RMAN:
>    ```
>    rman target /
>    CROSSCHECK ARCHIVELOG ALL;
>    DELETE NOPROMPT ARCHIVELOG ALL;     -- safe: NOARCHIVELOG, throwaway clone, 19c source intact
>    ```
>    Verify `v$recovery_area_usage` ARCHIVED LOG drops to ~0%.

## Stage 7 — ISG REST (KA1055 section 11) (automatable + interactive deploy)
Per KA1055 section 11.3: after a DB upgrade, **REST = validate only** (no special REST rebuild). Once
Gate C passes (APPS auth healthy):
1. `ant -f $JAVA_TOP/oracle/apps/fnd/isg/ant/isgDesigner.xml -Dfile=.../isg_service.xml` validate.
2. `provider/isActive/` → expect `ACTIVE`.
3. If runtime invocation of a previously-deployed service errors, redeploy it from iRep (KA1055 section 11.3).
4. Deploy our custom REST packages (XX_COLLECTIONS_REST_PKG etc.) + grant to responsibility/user.
   (Patch 37288906/37323421 are the ISG interop patches from KA1151 section 2 — ensure applied.)

## Stage 8 — 26ai AI platform rebuild (our solution layer) (automatable)
Re-apply the working 26ai setup (independent of ISG; documented in `.kiro/steering/26ai.md` and
SOLUTION_OVERVIEW.md). Idempotent deployer: `collections_agent/scripts/deploy_ai_layer.sh`.
1. **Prereqs (above):** COMPATIBLE=23.26.0 + vector_memory_size set + FRA cleared.
2. COLLECTIONS_AI schema + XXC_DATA tablespace.
3. DBMS_CLOUD family under `C##CLOUD$SERVICE` (catclouduser.sql THEN dbms_cloud_install.sql).
4. SSL wallet + `SSL_WALLET` property at CDB root; network ACL + wallet ACE for Bedrock.
5. Bedrock credential (long-lived IAM keys) + SELECT AI profile EBS_COLLECTIONS (Claude Sonnet 4.5).
   - ⚠️ **In-DB SELECT AI Bedrock call fails on 23.26.2** (DBMS_CLOUD_AI signs SigV4 as `s3://` →
     ORA-20401 / hung session). NL→SQL is done by the **AgentCore Strands agent (boto3 Bedrock)**
     instead (proven). Profile stays configured for a future RU fix.
6. **In-DB ONNX embedding model** (all_MiniLM_L12_v2, 384-dim) via `load_onnx_model.sh` (pull from
   S3 — the 133MB file has no DB internet egress; **verify byte size = 133,322,334**, a truncated
   upload causes `ORA-54401 protobuf parsing failed`). Embed KB docs; `XX_KB_SEARCH_PKG` vector search.
7. 6 deterministic reporting views over live EBS AR (dashboard data layer).
8. Deterministic + vector layers are the demo surface; ORDS/APEX optional (React UI calls AgentCore).

## Stage 9 — Final validation
- NL→SQL: AgentCore `execute_oracle_ai_query` (Bedrock→SQL→oracledb) returns live rows.
- In-DB vector KB search returns ranked docs (semantic_ready=TRUE).
- Deterministic views return live EBS data.
- **ISG isActive = ACTIVE; a write-back action (e.g. create note) succeeds via ISG REST.**
- FNDCPASS APPLSYS change succeeds cleanly (proves credential chain healthy).

---

## Decision points where I will pause for you (everything else runs autonomously)
1. **DB AutoUpgrade `-mode deploy`** (Stage 5) — long, highest-risk; I confirm analyze/fixups are
   clean before deploy, and confirm before the post-deploy DB restart.
2. **Any interactive password prompt** (adop, txkPostPDBCreationTasks, FNDCPASS, AFPASSWD) that
   can't be safely piped — I'll ask you to type it in the live SSM session, or confirm I may feed it.
3. **Gate B / Gate C failure** — if the credential verifier check fails, I stop and propose the
   FNDCPASS fix rather than pressing on into the dead-end.
4. **Destructive/irreversible** steps (dropping editions, compatible bump, cutover) — confirm first.

Everything else — patch staging via S3, ETCC, AutoConfig, listener/TNS gen, JAR regen, ORDS/APEX,
SELECT AI/vector setup, validation queries — I run unattended and report results.
