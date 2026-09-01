/* ------------------------------------------------------------------
   Fill these two values in, then this portal is live.

   Supabase dashboard -> Project Settings -> Data API (or API):
     SUPABASE_URL       "Project URL"
     SUPABASE_ANON_KEY  the "anon" / "publishable" key

   The anon key is designed to sit in client-side code and be public.
   It is NOT a secret. Every protection in this portal comes from Row
   Level Security in the database, which is why the leak test in
   TEST_PLAN.md matters more than hiding this value.

   NEVER put the `service_role` / secret key in this file. It bypasses
   Row Level Security entirely — anyone who opened the page could then
   read all 512 vendors' bank details.
------------------------------------------------------------------ */

window.SUPABASE_URL      = "https://wokaoqxsualvypgtfnjg.supabase.co";
window.SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Indva2FvcXhzdWFsdnlwZ3RmbmpnIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODY5MDQxMjQsImV4cCI6MjEwMjQ4MDEyNH0.tWXMuLleDtHoebQYKkKpBByBGKI9C7tfzPtvHDqAdFk";

/* Shown in the header. Change freely. */
window.PORTAL_ORG = "IKIO Solutions Private Limited";

/* Where sign-in links should send people.
   Leave empty while testing on this machine. Once deployed, set it to the
   public URL — otherwise invitations you send will contain a localhost
   link, which works only on your own computer and nowhere else.
   The same URL must also be listed in Supabase under
   Authentication -> URL Configuration -> Redirect URLs. */
window.PORTAL_URL = "";

/* Set to false once you are collecting real vendor data — it removes the
   "do not enter real bank details" banner. Leave true while testing. */
window.PORTAL_TEST_MODE = true;

/* ---- Where banking data goes -------------------------------------
   Three modes. Change ONE line here; the rest of the portal follows.

   "supabase"  Bank details are stored in Supabase, as originally built.
               Requires fix-07 NOT to have been run. Use this while
               testing with mock data only — it does not satisfy the
               "no banking data in third-party cloud databases" rule.

   "worker"    Bank details are posted to PORTAL_WORKER_URL, which
               forwards them to on-premise SAP. Nothing is stored here.
               Requires fix-07 applied AND the Worker deployed.

   "off"       Bank details are not collected at all. The fields are
               never rendered, so no code path can put an account number
               in this database. Registrations submit without them and
               finance collects bank details separately.

   Switching supabase -> off is safe at any time.
   Switching to "worker" requires fix-07 first, or the portal will call
   functions that no longer exist. See STATUS.md. */
window.PORTAL_BANK_MODE = "supabase";

/* Only used when PORTAL_BANK_MODE is "worker". */
window.PORTAL_WORKER_URL = "";

/* Document slots offered to vendors.

   IMPORTANT: a cancelled cheque shows the account number and IFSC, and a
   signed VRF may too. These upload into Supabase STORAGE, which is the
   same third-party cloud the banking rule is about — dropping the
   vendor_bank_details table does not cover them.

   Set this to false when the compliance boundary takes effect, so
   banking data cannot enter Supabase as an image instead of a column. */
window.PORTAL_ALLOW_BANK_DOCUMENTS = true;
