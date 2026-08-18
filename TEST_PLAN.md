# Test plan — before any real vendor gets an email

Two parts: mock data your staff can safely type in, and a leak test you must
run yourself. The leak test is the one that matters. The rest checks that the
form works; the leak test checks that 512 vendors' bank accounts aren't
readable by anyone who signs up.

---

## Mock data (fictional — safe to circulate)

Fields follow the VRF form order. Vendor C is deliberately an overseas vendor,
to exercise the SWIFT-instead-of-IFSC path.

| Field | Vendor A (India, MSME) | Vendor B (India, non-MSME) | Vendor C (overseas) |
|---|---|---|---|
| Company Name | Meridian Polymers Pvt Ltd | Kestrel Sheet Metal Co | Halden Optics GmbH |
| Country | India | India | Germany |
| Region / State | Uttar Pradesh | Delhi | Bavaria |
| Address 1 | Plot 44, Sector 63 | B-12, Okhla Phase II | Lindenstrasse 9 |
| City / PIN | Noida / 201301 | New Delhi / 110020 | Munich / 80331 |
| Payment Terms | 45 days from invoice | 30 days from invoice | 50% advance, 50% on shipment |
| Order Currency | INR | INR | EUR |
| INCO Terms | EXW | FOB | CIF |
| Telephone / Mobile | 01204455661 / 9876500011 | 01126677881 / 9876500022 | +49 89 555010 / +49 170 5550111 |
| Contact — Sales | R. Menon | S. Kaur | M. Brandt |
| E-mail — Sales | sales@meridian.example | sales@kestrel.example | sales@halden.example |
| Contact — Finance | A. Iyer | P. Chawla | K. Vogel |
| E-mail — Finance | accounts@meridian.example | accounts@kestrel.example | ap@halden.example |
| PAN | `AAACM1234F` | `AABCK5678G` | — |
| TAN | `DELM12345B` | `DELK67890C` | — |
| GSTIN | `09AAACM1234F1Z5` | `07AABCK5678G1Z2` | — |
| MSMED covered | Yes (upload any dummy PDF) | No | — |
| Nature of Work | Injection moulded housings | Sheet metal fabrication | Optical lenses |
| Beneficiary Name | Meridian Polymers Pvt Ltd | Kestrel Sheet Metal Co | Halden Optics GmbH |
| Bank Name & Address | HDFC Bank, Sector 62, Noida | ICICI Bank, Okhla, New Delhi | Commerzbank, Munich |
| Account No. | `112233445566` | `998877665544` | `DE89370400440532013000` |
| IFSC | `HDFC0001234` | `ICIC0005678` | — |
| SWIFT | — | — | `COBADEFFXXX` |

Deliberately invalid values, to confirm validation actually bites:

- GSTIN `09AAACM1234F1Z` — 14 chars, must be rejected
- PAN `AAAC1234F` — wrong shape, must be rejected
- TAN `DEL12345B` — only 3 leading letters, must be rejected
- IFSC `HDFC1001234` — 5th character is not `0`, must be rejected
- Account number `12345` — too short, must be rejected
- Account number `112233445566` vs `112233445567` in the two boxes — mismatch
- Vendor A with MSMED = Yes but no certificate uploaded — submit must fail
  with "MSMED certificate must be attached when covered under the Act."
- Vendor C submitted with no SWIFT — must fail with "SWIFT code is required
  for overseas bank accounts."

---

## Functional checks

1. Log in as yourself, run the role-seed statements at the bottom of
   `schema.sql` (give yourself `approver`, and a second staff account
   `checker`). Log out and back in. You land on `/staff`.
2. Log in as a vendor test account. You land on `/register`, never `/staff`.
   *(If a non-staff user ever reaches `/staff`, stop and fix before going on.)*
3. Fill Step 1 for Vendor A, Save draft, close the tab, log back in — the
   data is still there.
4. Work through every invalid value above. Each is refused with a readable
   message.
5. Complete and submit Vendor A. The form goes read-only and the account
   shows as `••••5566`, not the full number.
6. Try to edit after submitting. It must fail. Test this with the UI controls
   re-enabled via devtools, not just by clicking — RLS is what should stop it.
7. On `/staff` all three vendors are listed, with **no bank column**.
8. Click **Reveal bank details** on Vendor A. Full details appear.
9. As the checker account, mark Vendor A checked. As yourself (approver),
   approve it. Then try to approve Vendor B **without** checking it first —
   must fail with "A registration must be checked before it is approved."
10. Give one account both roles in turn and try to check and approve the same
    vendor — must fail with "The same person cannot both check and approve."
11. In Supabase → Table editor → `audit_log`: there is a
    `bank_details.revealed` row naming you and Vendor A, plus `status.check`
    and `status.approve` rows. **If step 8 happened but no audit row exists,
    the reveal is bypassing the RPC — fix that before go-live.**

---

## The leak test (do not skip)

Confirms a logged-in vendor cannot read another vendor's data or any bank
details, using the public anon key exactly as an attacker would. Get the
project URL and anon key from Supabase → Settings → API. The anon key is
public by design; the whole model assumes an attacker holds it.

Signed in as a **non-staff** test user, every one of these must return zero
rows or an error:

```js
await s.from('vendor_bank_details').select('*');   // error / empty
await s.from('vendors').select('*');               // exactly 1 row — their own
await s.from('user_roles').select('*');            // error / empty
await s.from('audit_log').select('*');             // error / empty
await s.from('vendor_documents').select('*');      // only their own
await s.storage.from('vendor-docs').list('<other vendor id>');  // empty
await s.rpc('staff_reveal_bank_details', { p_vendor_id: '<vendor A id>' });
                                                   // "Not authorised…"
await s.rpc('advance_status', { p_vendor_id: '<id>', p_action: 'approve' });
                                                   // "Only an approver…"
```

Then the self-promotion attempt — the failure mode Lovable-generated apps most
often ship with:

```js
await s.auth.updateUser({ data: { role: 'approver' } });
await s.from('vendors').select('*');   // must STILL return only their own row
```

If that last query returns more than one row, something is reading roles from
user metadata. Find it and route it through `has_role()` / `is_staff()`.

---

## Before real vendors

- Replace Supabase's built-in email sender with real SMTP (Resend, SES,
  Postmark). The built-in one is rate-limited for testing and will silently
  drop most of 512 invitations. Warm the domain — bulk mail from a fresh
  domain to corporate inboxes lands in spam.
- Remove the "TEST ENVIRONMENT" banner.
- Delete the mock vendors, their documents, and their auth users.
- Decide whether the signed-and-stamped VRF is still required as an upload
  (`doc_type = 'signed_vrf'`) or whether the portal submission replaces it.
  That is a policy question for whoever owns vendor onboarding.
- Pilot with five friendly vendors for a few days before the other 507.
