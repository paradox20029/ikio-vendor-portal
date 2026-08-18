# Lovable build prompts — Vendor Registration Portal (IKIO Solutions Pvt Ltd)

Field list mirrors the existing "VRF ISPL" paper form exactly, including the
Initiated / Checked / Approved sign-off chain at the bottom of it.

Order: Prompt 1 scaffolds → run `schema.sql` in Supabase → Prompts 2–4.

---

## Prompt 0 — invitations and staff allocation

Paste this **first**. It covers the invite-and-allocate flow: staff invite a
known supplier, allocate it to an owner, and that owner is the only person who
sees the submission.

> Add an invitation flow to a Supabase-backed vendor portal.
>
> **Staff screen `/invite`:** a form with Vendor Name, Vendor Email, and an
> "Allocated staff member" dropdown listing internal staff. Submitting calls
> `supabase.rpc('create_invitation', { p_vendor_name, p_vendor_email,
> p_allocated_staff_id })`. Below it, a table of invitations read from
> `vendor_invitations` showing name, email, allocated owner, status and
> expiry. Staff only see invitations allocated to them; approvers see all.
>
> **Invitation email:** send the invited address a Supabase **magic link**
> (`signInWithOtp`) pointing at the portal. Do NOT put the invitation id in
> the URL and do NOT treat holding a URL as being logged in.
>
> **First login:** immediately after a vendor's first successful sign-in,
> call `supabase.rpc('claim_invitation')` once. It matches the invitation to
> the email they just proved they control, creates their vendor record
> already allocated to the right staff member, and returns its id. If it
> raises "No invitation exists for this email address", show a plain page
> saying to contact their IKIO representative — do not offer self-signup.
>
> **Staff queue:** each staff member sees only the vendors allocated to them.
> Do not filter this in the frontend only; the database already enforces it,
> so just read `vendor_overview` and render what comes back.

---

## Prompt 1 — scaffold

> Build a vendor registration portal for IKIO Solutions Private Limited.
> Use Supabase for auth and database.
>
> **Auth:** email magic-link login only, no passwords. After login, route by
> role: internal staff go to /staff, everyone else goes to /register.
>
> **Vendor form (/register)** — three steps, matching our paper form:
>
> *Step 1 — Company details:* Company Name, Country (dropdown, default India),
> Region/State, Address 1, Address 2, Address 3, City, PIN Code,
> Payment Terms, Order Currency (INR/USD/EUR/GBP/AED),
> INCO Terms (EXW/FOB/CIF/CFR/DDP/DAP), Telephone No., Mobile No., FAX No.,
> Contact Person — Sales, E-Mail ID — Sales,
> Contact Person — Finance & Accounts, E-Mail ID — Finance & Accounts,
> Nature of Work (multiline).
>
> *Step 2 — Statutory & bank:* PAN No., TAN No., GSTIN No.,
> "Whether covered under the MSMED Act" (Yes/No radio) and, when Yes,
> a required file upload for the MSMED certificate.
> Then Beneficiary Name, Bank Name & Address (multiline), Bank A/c No.
> (entered twice, must match), Bank IFSC Code, and SWIFT Code.
>
> *Step 3 — Documents & review:* optional uploads for GST certificate, PAN
> card, and cancelled cheque; then a read-only summary of everything
> entered, and a Submit button with a confirmation dialog.
>
> **Conditional fields:** when Country is India, show PAN/TAN/GSTIN/MSMED and
> IFSC, and hide SWIFT. When Country is anything else, hide the Indian
> statutory fields and MSMED, and require SWIFT instead of IFSC.
>
> **Validation (client-side):**
> - GSTIN: `^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$`
> - PAN: `^[A-Z]{5}[0-9]{4}[A-Z]$`
> - TAN: `^[A-Z]{4}[0-9]{5}[A-Z]$`
> - IFSC: `^[A-Z]{4}0[A-Z0-9]{6}$`
> - SWIFT: `^[A-Z]{6}[A-Z0-9]{2}([A-Z0-9]{3})?$`
> - Account number: 9–34 alphanumeric, and the two entries must match exactly.
> Uppercase these fields automatically as the user types.
>
> "Save draft" is always available. After submit the form becomes read-only
> and shows the status, with the account number masked to the last 4 digits.
>
> **Staff page (/staff):** table of all registrations — company name, country,
> GSTIN, contact, status, submitted date. **No bank column.** Clicking a row
> opens a detail panel where the account shows masked (••••1234) with a
> "Reveal bank details" button. Staff actions depend on role: a checker sees
> "Mark as checked", an approver sees "Approve", both see "Reject" and
> "Send back for correction", each with a remarks field.
>
> Do NOT read roles from user metadata anywhere in the frontend — roles come
> from a `user_roles` table. I will supply the database schema myself.

---

## Between prompts: run `schema.sql`

Supabase dashboard → SQL editor → paste all of `schema.sql` → Run. It replaces
Lovable's generated tables with ones that carry the security model, and creates
the private `vendor-docs` storage bucket. Then log in once with your own email
and run the role-seed statements at the bottom of the file.

---

## Prompt 2 — wire to the real schema

> Connect to this schema exactly.
>
> - `vendors` — one row per vendor, `user_id = auth.uid()`. All the company,
>   address, terms, contact and statutory columns live here, plus `status`
>   ('draft' | 'submitted' | 'checked' | 'approved' | 'rejected').
> - `vendor_bank_details` — `vendor_id` references `vendors.id`; columns
>   `beneficiary_name`, `bank_name_addr`, `account_number`, `ifsc_code`,
>   `swift_code`. This table is **write-only** for vendors: insert and update
>   while status is draft, never selected directly. To show the masked
>   account back to the vendor, call `supabase.rpc('get_my_bank_last4')`.
> - `vendor_documents` — metadata rows. Upload the file to the private
>   `vendor-docs` storage bucket at path `<vendor_id>/<filename>` first, then
>   insert the row with `doc_type` one of `msmed_certificate`,
>   `gst_certificate`, `pan_card`, `cancelled_cheque`, `signed_vrf`, `other`.
>   The path prefix must be the vendor id — storage policies key off it.
> - Submitting calls `supabase.rpc('submit_registration')`. Do not update
>   `status` directly from the client; the RPC does the completeness checks.
> - Staff list reads the `vendor_overview` view (no bank columns).
> - Reveal calls `supabase.rpc('staff_reveal_bank_details', { p_vendor_id })`.
> - Staff actions call
>   `supabase.rpc('advance_status', { p_vendor_id, p_action, p_remarks })`
>   with `p_action` of `check`, `approve`, `reject` or `reopen`.
>
> Every RPC can raise. Surface the returned message verbatim in a toast —
> e.g. "Only a checker may check a registration", "The same person cannot
> both check and approve a vendor", "MSMED certificate must be attached".
> These are the real business rules, so the user needs to read them.

---

## Prompt 3 — role-aware UI

> Fetch the current user's role once after login by calling
> `supabase.rpc('has_role', { p_role: 'checker' })` and again for 'approver',
> and cache it in context. Show the "Mark as checked" button only to a
> checker and "Approve" only to an approver. Treat this as cosmetic only —
> the database enforces it regardless, so never rely on hiding a button.
>
> Show the sign-off trail on the detail panel: who checked it and when, who
> approved it and when, read from `checked_at` / `approved_at`.

---

## Prompt 4 — polish

> - Empty and loading states; header with the logged-in email and a logout button.
> - Step indicator (Step 1 of 3) and a progress bar on /register.
> - Mobile-friendly — vendors will often fill this on a phone.
> - A "Test mode" banner across the top reading
>   "TEST ENVIRONMENT — do not enter real bank details".
>   I will remove it before go-live.
