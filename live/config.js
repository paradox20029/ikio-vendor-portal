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
