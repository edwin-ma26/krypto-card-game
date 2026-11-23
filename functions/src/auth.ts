/** Email lookup for the "Continue with email" sign-in flow.
 *
 * The app asks for an email first and only then shows either a password
 * page (existing account) or a create-account page (new). Firebase's
 * email-enumeration protection (on by default) makes the client-side
 * `fetchSignInMethods` lookup return nothing, so the check runs here with
 * the Admin SDK instead. This does let a caller probe whether an address
 * has an account — an accepted trade for a puzzle game with nothing
 * sensitive behind the login — so it's kept narrow: POST only, one email
 * per call, a yes/no answer plus which sign-in methods exist (so the app
 * can say "you signed up with Apple" instead of asking for a password that
 * doesn't exist), and nothing else about the account. */

import { onRequest } from "firebase-functions/v2/https";
import { getAuth } from "firebase-admin/auth";
import { logger } from "firebase-functions/v2";

const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

export const checkEmail = onRequest({ cors: false, timeoutSeconds: 10 }, async (req, res) => {
  if (req.method !== "POST") {
    res.status(405).json({ error: "POST only" });
    return;
  }
  const raw = typeof req.body?.email === "string" ? req.body.email : "";
  const email = raw.trim().toLowerCase();
  if (!email || email.length > 254 || !EMAIL_PATTERN.test(email)) {
    res.status(400).json({ error: "invalid email" });
    return;
  }

  try {
    const user = await getAuth().getUserByEmail(email);
    const providers = user.providerData.map((p) => p.providerId); // e.g. "password", "google.com", "apple.com"
    res.json({ exists: true, providers });
  } catch (error) {
    const code = (error as { code?: string }).code;
    if (code === "auth/user-not-found") {
      res.json({ exists: false, providers: [] });
      return;
    }
    logger.error("checkEmail failed", error);
    res.status(500).json({ error: "lookup failed" });
  }
});
