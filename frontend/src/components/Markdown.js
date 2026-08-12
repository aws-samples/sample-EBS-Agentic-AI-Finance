import React from "react";

// Minimal, dependency-free markdown renderer for agent replies.
// Handles the subset the agent actually emits: headings, **bold**, *italic*,
// `inline code`, bullet lists (-, *, •), numbered lists, and blank-line paragraphs.
// It intentionally STRIPS images / chart URLs — the chart is rendered separately as
// an <img> by the caller (extractChart), so we don't want a broken/duplicate link.
// Renders React elements (no dangerouslySetInnerHTML) so untrusted text stays safe.

// Inline formatting: bold, italic, code. Returns an array of React nodes.
function renderInline(text, keyPrefix) {
  const nodes = [];
  // Split on **bold**, *italic*/_italic_, and `code`, keeping the delimiters.
  const parts = text.split(/(\*\*[^*]+\*\*|`[^`]+`|(?<!\*)\*[^*\n]+\*(?!\*)|_[^_\n]+_)/g);
  parts.forEach((p, i) => {
    if (!p) return;
    const key = `${keyPrefix}-i${i}`;
    if (/^\*\*[^*]+\*\*$/.test(p)) {
      nodes.push(<strong key={key}>{p.slice(2, -2)}</strong>);
    } else if (/^`[^`]+`$/.test(p)) {
      nodes.push(<code key={key}>{p.slice(1, -1)}</code>);
    } else if (/^\*[^*]+\*$/.test(p)) {
      nodes.push(<em key={key}>{p.slice(1, -1)}</em>);
    } else if (/^_[^_]+_$/.test(p)) {
      nodes.push(<em key={key}>{p.slice(1, -1)}</em>);
    } else {
      nodes.push(<React.Fragment key={key}>{p}</React.Fragment>);
    }
  });
  return nodes;
}

// Remove markdown image syntax and bare chart/data URLs (rendered separately as <img>),
// plus the hidden [[CONFIRM:{...}]] side-channel marker the agent appends to write
// confirmations (it rides in the reply/history so a next-turn "yes" executes the exact
// action deterministically, but must never be shown to the user).
function stripImages(text) {
  return (text || "")
    .replace(/\[\[CONFIRM:\{[\s\S]*?\}\]\]/g, "")           // hidden confirm marker
    .replace(/!\[[^\]]*\]\([^)]*\)/g, "")                 // ![alt](url)
    .replace(/data:image\/png;base64,[A-Za-z0-9+/=]+/g, "") // inline data URL
    .replace(/https:\/\/\S+charts\/\S+\.png\S*/gi, "")      // bare presigned chart URL
    .replace(/\[[^\]]*\]\((https:\/\/[^)\s]+\.png[^)\s]*)\)/gi, ""); // [text](…png)
}

export default function Markdown({ text }) {
  if (!text) return null;
  const src = stripImages(text);
  const lines = src.split(/\r?\n/);

  const blocks = [];
  let list = null;      // { ordered: bool, items: [] }
  let para = [];        // buffer of plain lines forming a paragraph

  const flushPara = () => {
    if (para.length) {
      const key = `p${blocks.length}`;
      blocks.push(<p key={key}>{renderInline(para.join(" "), key)}</p>);
      para = [];
    }
  };
  const flushList = () => {
    if (list) {
      const key = `l${blocks.length}`;
      const items = list.items.map((it, i) => <li key={`${key}-${i}`}>{renderInline(it, `${key}-${i}`)}</li>);
      blocks.push(list.ordered ? <ol key={key}>{items}</ol> : <ul key={key}>{items}</ul>);
      list = null;
    }
  };

  // Parse a GFM pipe-table row into trimmed cells (drops the leading/trailing pipe).
  const splitRow = (s) => s.replace(/^\s*\|/, "").replace(/\|\s*$/, "").split("|").map((c) => c.trim());
  // GFM table separator row, e.g. "| --- | :--: |". Validated by splitting on '|' and
  // checking each cell against a simple linear regex — avoids the nested-quantifier
  // pattern that Semgrep flags as ReDoS-prone (detect-redos).
  const isTableSep = (s) => {
    if (!s.includes("-")) return false;
    const cells = s.replace(/^\s*\|/, "").replace(/\|\s*$/, "").split("|");
    return cells.length > 0 && cells.every((c) => /^\s*:?-{2,}:?\s*$/.test(c));
  };

  for (let idx = 0; idx < lines.length; idx++) {
    const raw = lines[idx];
    const line = raw.replace(/\s+$/, "");
    if (!line.trim()) { flushPara(); flushList(); continue; }

    // GFM table: a header row `| a | b |` immediately followed by a `| --- | --- |` separator.
    if (line.includes("|") && idx + 1 < lines.length && isTableSep(lines[idx + 1])) {
      flushPara(); flushList();
      const header = splitRow(line);
      const rows = [];
      let j = idx + 2;
      while (j < lines.length && lines[j].includes("|") && lines[j].trim()) {
        rows.push(splitRow(lines[j]));
        j++;
      }
      const key = `t${blocks.length}`;
      blocks.push(
        <table key={key} className="md-table">
          <thead>
            <tr>{header.map((h, i) => <th key={`${key}-h${i}`}>{renderInline(h, `${key}-h${i}`)}</th>)}</tr>
          </thead>
          <tbody>
            {rows.map((r, ri) => (
              <tr key={`${key}-r${ri}`}>
                {header.map((_, ci) => <td key={`${key}-r${ri}c${ci}`}>{renderInline(r[ci] || "", `${key}-r${ri}c${ci}`)}</td>)}
              </tr>
            ))}
          </tbody>
        </table>
      );
      idx = j - 1;
      continue;
    }

    const heading = line.match(/^(#{1,4})\s+(.*)$/);
    const bullet = line.match(/^\s*[-*•]\s+(.*)$/);
    const numbered = line.match(/^\s*\d+[.)]\s+(.*)$/);

    if (heading) {
      flushPara(); flushList();
      const level = heading[1].length;
      const key = `h${blocks.length}`;
      const Tag = `h${Math.min(level + 2, 6)}`; // map # -> h3 so it fits the bubble
      blocks.push(<Tag key={key}>{renderInline(heading[2], key)}</Tag>);
    } else if (bullet) {
      flushPara();
      if (!list || list.ordered) { flushList(); list = { ordered: false, items: [] }; }
      list.items.push(bullet[1]);
    } else if (numbered) {
      flushPara();
      if (!list || !list.ordered) { flushList(); list = { ordered: true, items: [] }; }
      list.items.push(numbered[1]);
    } else {
      // A continuation line of a list item, or a paragraph line.
      if (list) list.items[list.items.length - 1] += " " + line.trim();
      else para.push(line.trim());
    }
  }
  flushPara(); flushList();

  return <div className="md">{blocks}</div>;
}
