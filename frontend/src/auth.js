// Cognito auth helpers (amazon-cognito-identity-js, no Amplify dependency).
import {
  CognitoUserPool,
  CognitoUser,
  AuthenticationDetails,
} from "amazon-cognito-identity-js";
import awsConfig from "./aws-config";

function pool() {
  return new CognitoUserPool({
    UserPoolId: awsConfig.userPoolId,
    ClientId: awsConfig.userPoolClientId,
  });
}

// Holds the in-flight CognitoUser when Cognito demands a first-login password change,
// so completeNewPassword() can finish the same challenge on the same user object.
let _pendingUser = null;

// Resolves to { status: "OK", token } on success, or { status: "NEW_PASSWORD_REQUIRED" }
// when the account is in FORCE_CHANGE_PASSWORD state (admin-created temp password). In the
// latter case the UI collects a new password and calls completeNewPassword().
export function signIn(email, password) {
  return new Promise((resolve, reject) => {
    const user = new CognitoUser({ Username: email, Pool: pool() });
    const details = new AuthenticationDetails({ Username: email, Password: password });
    user.authenticateUser(details, {
      onSuccess: (session) => resolve({ status: "OK", token: session.getIdToken().getJwtToken() }),
      onFailure: (err) => reject(err),
      newPasswordRequired: () => {
        _pendingUser = user;
        resolve({ status: "NEW_PASSWORD_REQUIRED" });
      },
    });
  });
}

// Complete a first-login password change against the user captured by signIn().
// Pass {} for attributes — email/email_verified are non-mutable here and would be rejected.
export function completeNewPassword(newPassword) {
  return new Promise((resolve, reject) => {
    if (!_pendingUser) {
      return reject(new Error("No password change in progress — please sign in again."));
    }
    _pendingUser.completeNewPasswordChallenge(newPassword, {}, {
      onSuccess: (session) => {
        _pendingUser = null;
        resolve({ status: "OK", token: session.getIdToken().getJwtToken() });
      },
      onFailure: (err) => reject(err),
    });
  });
}

export function currentToken() {
  return new Promise((resolve) => {
    const user = pool().getCurrentUser();
    if (!user) return resolve(null);
    user.getSession((err, session) => {
      if (err || !session.isValid()) return resolve(null);
      resolve(session.getIdToken().getJwtToken());
    });
  });
}

export function signOut() {
  const user = pool().getCurrentUser();
  if (user) user.signOut();
}

// Decode the (already-verified) Cognito ID token's claims client-side for display only.
// Server-side enforcement still re-verifies the signature — this is purely for the UI.
export function decodeIdentity(token) {
  try {
    const payload = JSON.parse(atob(token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/")));
    const groups = payload["cognito:groups"] || [];
    const email = payload.email || payload["cognito:username"] || "";
    const name = payload.name || (email ? email.split("@")[0] : "");
    // Human-friendly role label from the group set.
    const has = (g) => groups.includes(g);
    let role = "Read-only";
    if (has("ar-managers") && has("ap-managers")) role = "AR + AP Manager";
    else if (has("ar-managers")) role = "AR Collections Manager";
    else if (has("ap-managers")) role = "AP Manager";
    else if (has("ar-analysts")) role = "AR Analyst (read-only)";
    else if (has("ap-clerks")) role = "AP Clerk (read-only)";
    return { name, email, groups, role, ebsUsername: payload["custom:ebs_username"] || "" };
  } catch {
    return { name: "", email: "", groups: [], role: "", ebsUsername: "" };
  }
}
