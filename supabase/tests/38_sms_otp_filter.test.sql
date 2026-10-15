-- The SMS OTP filter (20261012212011, audit IOS-10): one pattern for the phone and the server.
--
-- The jsonb fixture below (dollar-quoted with the sms_otp_fixture tag) is shared: this test runs
-- it against private.sms_is_otp, and LedgerKit's SMSOTPParityTests reads this same file and runs
-- it against SMSCapture. Both check their pattern string equals `pattern`, so the two filters
-- are the same string, and both agree on every body in it.
--   • `otp`: must be dropped (never stored).
--   • `not_otp`: must be sent and stored. It holds every `sms_templates` example body (a test
--     below fails when a template example is missing: add it here, under `otp` only if it really
--     is a passcode). A false positive loses a real transaction for good.
-- A pattern change goes in all three places: a new migration, this fixture and
-- SMSCapture.otpPattern.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

create temp table fx as select $sms_otp_fixture${
 "pattern": "(^|[^a-zA-Z0-9_])otp([^a-zA-Z_]|$)|one[^a-zA-Z0-9]{0,3}time[^a-zA-Z0-9]{0,3}(password|pin|code)|verification[^a-zA-Z0-9]{0,3}(code|pin)|pass[^a-zA-Z0-9]?code|security[^a-zA-Z0-9]{0,3}code|authentication[^a-zA-Z0-9]{0,3}(code|pin|password)|secure[^a-zA-Z0-9]{0,3}code|3[^a-zA-Z0-9]?d[^a-zA-Z0-9]?secure[^a-zA-Z0-9]{1,3}(password|pin)|(^|[^a-zA-Z0-9.,])[0-9]{4,8}[^a-zA-Z0-9]{1,3}(is|as)[^a-zA-Z0-9]{1,3}(your|the)[^a-zA-Z0-9]{1,3}([a-zA-Z-]{1,20}[^a-zA-Z0-9]{1,3}){0,3}(code|pin|password|passcode)([^a-zA-Z]|$)|(do[^a-zA-Z0-9]{1,3}not|don[^a-zA-Z0-9]{0,2}t|never)[^a-zA-Z0-9]{1,3}share[^a-zA-Z0-9]{1,3}((this|the|your|it)[^a-zA-Z0-9]{1,3})?(otp|code|password|passcode)|رمز (ال)?تحقق|رمز (ال)?مرور|كلمة (ال)?مرور|كلمة (ال)?سر|(رمز|كود) لمرة واحدة",
 "otp": [
  "Your OTP for AED 250.00 at AMAZON on card ending 1234 is 482913.",
  "482913 is your One-Time Password for the transaction of AED 12.00 on Credit Card XXX1234",
  "Use one time passcode 1234 to complete your purchase",
  "Your onetime PIN is 9921",
  "Verification code: 551204. Do not share it.",
  "Your passcode is 1234",
  "Your pass code is 1234",
  "Security code 8812 for your FAB Credit Card transaction of USD 20.00",
  "OTP:123456 for txn of AED 99",
  "Use 482913 as the code to complete your purchase of AED 99.00 at AMAZON.AE with your Credit Card ending 9219. Never share this code.",
  "Your authentication code for Credit Card XX9208 transaction of AED 20.00 is 552211",
  "رمز التحقق الخاص بك هو 482913 لعملية شراء بقيمة 99.00 درهم على البطاقة المنتهية بـ 9219",
  "كلمة المرور لمرة واحدة هي 482913. لا تشاركها مع أحد",
  "رمز المرور 5521 لإتمام عملية الدفع",
  "رمز لمرة واحدة 5521 لإتمام عملية الشراء",
  "Your 3-D Secure password for the purchase of AED 120.00 at NOON is 7781",
  "Your 3D Secure code is 448812",
  "Your secure code for the transaction of AED 50.00 at CAREEM is 991234",
  "Mastercard SecureCode: 5521 for AED 30.00 at UBER",
  "Do not share this code. AED 1,250.00 at IKEA on card ending 5678 needs approval: 482913",
  "Don't share your password with anyone: 7731 confirms AED 15.00 at ENOC",
  "482913 is your code for card ending 9219",
  "Enter 663311 as your verification code",
  "One time code: 123456",
  "OTP123456 for AED 5.00 at NOON",
  "Dear Customer, to complete adding your card ending 9212 to the digital wallet, retrieve the OTP from the EI + App. If you don’t have the app, please download and register to view the OTP. Do not share your OTP !"
 ],
 "not_otp": [
  "تم تحصيل رسوم بقيمة 50.00 درهم لمرة واحدة على بطاقتك المنتهية بـ 1234",
  "A Cr. transaction of AED 1100.00 on your account number XXX310001 was successful.Available balance is 1105.04.",
  "A new login to Mobile/Online Banking has been authorised on your device.",
  "A payment on your card needs confirmation. Please check your Emirates NBD app.",
  "A txn on your Covered Card XXXX9213 at EMIRATES for INR 28,400.00 on 02-10-2026 09:36 is approved. Your available balance is AED 7,512.13",
  "A txn on your Covered Card XXXX9213 at INTEGRATED GAS SERVICE for AED 105.75 on 08-10-2026 11:23 is approved. Your available balance is AED 7,135.72",
  "A txn on your Covered Card XXXX9213 at NOQ*Ejari for AED 177.75 on 03-10-2026 14:36 is approved. Your available balance is AED 7,241.47",
  "A txn on your Covered Card XXXX9213 at Tesla Motors Netherlan for AED 1.00 on 02-10-2026 12:19 is declined. Your available balance is AED 7,459.22",
  "A txn on your Covered Card XXXX9213 at Tesla Motors Netherlan for AED 52.91 on 02-10-2026 12:19 is approved. Your available balance is AED 7,459.22",
  "Amount of AED 91.00 from NAMSHI has been credited to your card ending with 9219. Available limit is AED 19,532.39.",
  "Cr.Card XXX9208 Billing alert: Total due to avoid fin. charges: AED172.09. Due date Sep 18 2026; Pay min. AED100.00 by due date to avoid AED241.50 late fee",
  "Credit Card Mini Statement\nCard Starting: 459220\nStatement Date: 10/10/2026\nMinimum Amount Due: AED 229.45\nAmount to be paid to avoid charges:  AED 4,589.03\nDue Date: 04/11/2026\nPlease pay on or before due date to avoid commitment to donate amount.",
  "Credit Card Purchase\nCard Ending: 9212\nAt: NATIONAL TAXI, DUBAI\nAmount: AED 59.50\nDate: 16/09/2026, 12:14\nAvailable Limit: AED 36,957.01",
  "Credit Card Purchase\nCard No XXXX9206\nAED 133.96\nAPPLE.COM/BILL CORK IRL\n05/10/26 10:40\nAvl Bal AED 28335.60\nOctober statement due on 26/10/2026",
  "Credit Card XX9208 was used for EGP69.94 on 09/09/2026 11:44:55 at UBER *TRIP HELP.UBER, help.uber.com-NL. Available limit  AED19965.95",
  "Credit Card XX9208 was used for INR840.96 on 06/10/2026 12:43:13 at UBER * PENDING, help.uber.com-NL. Available limit AED26967.39",
  "Dear Customer, you have regained access to your EI+ Mobile/Online banking successfully. If this wasn't you, please call +971 600 599995 and report fraud.",
  "Dear Customer, you have successfully activated Smart Pass on your trusted device for your Mobile and Online Banking. If this wasn't you, please call +971 600 59 9995 and report fraud.",
  "Dear Customer, you've initiated a request to recover access to your ENBD X profile. If this wasn't you, please call +971 600 54 0000 and report fraud.",
  "Dear Customer, your card ending 9212 has been disabled from Apple Wallet. If you did not initiate this transaction, please call 600599995",
  "Dear Customer, your card ending 9212 has been enrolled into Apple Wallet. If you did not initiate this, please call 600599995",
  "Dear Customer, your funds transfer request of  AED 2,100.00 to IBAN/Account/Card XXXX9209  has been processed successfully from your account/ card XXXX9221 on 02/10/2026 14:19",
  "Dear Customer, Your Smart Pass has been deactivated from your old device, please continue transacting on the new device.",
  "Debit Card Purchase\nCard No XXXX1234\nAED 20.00\nCARREFOUR DUBAI\n05/10/26 10:40\nAvl Bal AED 100.00",
  "Debit card XXX9211 linked to acc. XXX320001 used for AED3.50 (+2.49% foreign txn fee) on Sep 11 2026  4:33PM at GOOGLEYOUTUBE M,US. Avl.Bal AED 51.54.",
  "Emirates NBD Credit Card Mini Stmt for Card ending 9219: Statement date 28/08/26. Total Amt Due AED 48.77, Due Date 22/09/26. Min Amt Due AED 48.77",
  "FAB Alert: Credit Card ending 7310 charged AED 64.00 by PARKVIEW PARKING on 06-10-2026 at 09:15. Call 600 000000 if not you.",
  "Login detected on FAB Mobile",
  "October statement due on 26/10/2026\nCredit Card Purchase\nCard No XXXX9203\nUSD 6.00\nINDIGO AIRLINES NEW YORK USA\n04/10/26 10:38",
  "Outward Remittance Debit\nAccount XXXX9221\nAED 2100.00\nDate 02/10/2026\nBalance AED 3644.98",
  "Payment for Credit Card ending 9219 is due on 22/09/26. Total Amt - AED 48.77; Min Amt - AED 48.77. Please pay by due date to avoid charges.",
  "Payment of AED 12.50 to noon one with Credit Card ending 9219. Avl Cr. Limit is AED 19,938.73.",
  "Payment of AED 42.00 to Noon with Credit Card ending 9219. Avl Cr. Limit is AED 19,951.23.",
  "Payment of AED 593.03 was done at Dubai Electricity using your Wio Personal card 9202 with Credit money",
  "Payment of AED 650 was done at Dubai Duty Free using your Wio Personal card 9202 with Credit money",
  "Purchase of AED 52.25 at OASIS FRESH MART,DUBAI with Credit Card ending 7310 on 03/10/2026 14:22. Available limit AED 38,120.55",
  "Purchase of AED 73.69 with Credit Card ending 9219 at Noon Minutes, Dubai. Avl Cr. Limit is AED 19,626.23",
  "Purchase of USD 20.00 at CODEFORGE.IO with Credit Card ending 7310 on 09/09/2026 04:00. Available limit AED 40,010.00",
  "Refund of AED 145.00 from ATLAS HOME STORE,DUBAI credited to Credit Card ending 7310 on 21/07/2026.",
  "Reversal of AED 850.00 on ADCB Credit Card XXX4821 at GRANDVIEW HOTEL on 05/10/2026.",
  "Review your transaction\nTap to approve your transaction at Vox Cinemas for AED46.00 on your ADCB Card XXX9208, valid for 10 minutes. If not initiated by you, please deny and call +971600502030",
  "Thank you for activating your new SIB Covered Card and accepting the updated Terms & Conditions. Your new card is now ready to use. Remember to update your card details across secure digital wallets and subscriptions. To view Terms & Conditions and Key Facts Statement, visit www.sib.ae/CSU",
  "Covered Card ending with XXXX9213 payment is due on 30-10-2026, outstanding amount is AED 4,396.67, minimum payment due is AED 219.83. Ensure paying before 30-10-2026 to avoid deducting any amount under commitment to donate clause.",
  "Your account number XXX310001 has been inactive since 2026.01.31. Kindly make a transaction to avoid account from becoming dormant.",
  "Your ADCB Credit Card XXX4821 was used for AED 52.25 at SAFFRON KITCHEN,DUBAI on 03/10/2026 14:22. Available limit: AED 21,345.10.",
  "Your ADCB Credit Card XXX4821 was used for EUR 86.40 at RESTAURANTE MIRADOURO on 13/09/2026 20:40. Available limit: AED 18,002.00.",
  "Your ADCB Debit Card XXX5530 was used for AED 120.00 at ATM DEIRA on 04/10/2026 18:40.",
  "Your Cr.Card XXX9208 was used for AED46.00 on 09/08/2026 13:43:40 at Vox Cinemas,Dubai-AE. Avl. Cr.limit is AED26953.75",
  "Your request to redeem TPs 5500 at Noon Food was successful on 22/09/2026 18:10:01. TPs balance: 265. Earn more with the TouchPoints app: adcb.com/tpapp",
  "Your statement of the card ending with 9206 dated 01Oct26 has been sent to you and can also be viewed in the new FAB mobile banking app. Download it from the App Store https://apple.co/FB7qEZ or Google Play https://goo.gl/7dXnNc. The total amount due is AED 515.26. Minimum due is AED 100.00. Due date is 26Oct26",
  "Your Username retrieval request is pending your authorisation.",
  "Your Wio Personal card ending with 9202 has been added to Apple Pay. If it wasn't you, freeze this card in the App and contact us immediately at 600 500 946",
  "Your FAB Credit Card XXX1234 was used for AED 45.10 at CARREFOUR CITY CENTRE on 08/10/2026 09:12. Avl limit AED 25,000.00",
  "Purchase of AED 1,250.00 with Credit Card ending 5678 at IKEA DUBAI. Available limit AED 10,212.50",
  "Your Cr.Card XXX4321 was used for USD 12.34 at AMAZON.COM on 07-OCT-26",
  "Transaction of AED 99.00 on your Mashreq Credit Card ending 0001 at NOON.COM",
  "Refund of AED 120.00 to your card ending 1234 from NOON has been processed",
  "Payment of AED 5,000.00 received for card ending 1234. Thank you.",
  "Txn of EUR 30.00 at ZARA PARIS on card 1234.",
  "Your credit card a/c ending 1234 has been charged AED 10.00 annual fee",
  "Your Debit Card ending 1234 was used for AED 45.00 at ENOC",
  "AED 12,000.00 salary credited to your a/c XXX9876. Avl bal AED 15,212.00",
  "Your account XXXX9876 has been debited AED 500.00 via transfer to JOHN",
  "Funds transfer of AED 1,000.00 completed",
  "Your DC ending 1234 was used for AED 10.00",
  "Purchase of Rs. 500 on card ending 1234 at CAFE",
  "Your new card has been dispatched.",
  "EmiratesNBD",
  "Your Credit Card XXX4821 was used for AED 52.25 at SECURE PARKING LLC on 03/10/2026. Approval code: 448812. Available limit AED 21,345.10",
  "Auth code 004512: AED 75.00 at CARREFOUR on Credit Card ending 1234",
  "Purchase of AED 1234.00 at THE CODE ACADEMY with Credit Card ending 9219",
  "Payment of AED 650 was done at ONE TIME FITNESS using your Wio Personal card 9202 with Credit money",
  "Transaction of AED 49.00 at ONETIME.COM on your Credit Card ending 0001",
  "Txn of AED 99.00 at PASSPORT PHOTO CENTRE on card 1234",
  "Your card ending 1234 was declined at AMAZON for AED 50.00: 3-D Secure authentication failed.",
  "Purchase of AED 120.00 at NOON with Credit Card ending 1234. Never share your card details with anyone.",
  "AED 2,500.00 is your available limit on Credit Card ending 1234",
  "Purchase of AED 300.00 at HOTPOT EXPRESS with Credit Card ending 7310",
  "Purchase of AED 15.00 at SHOP_OTP_STORE with Credit Card ending 1234",
  "عملية شراء بقيمة 99.00 درهم على البطاقة المنتهية بـ 9219 لدى نون"
 ]
}$sms_otp_fixture$::jsonb as j;

select is(private.sms_otp_pattern(), (select j->>'pattern' from fx),
          'the server''s OTP pattern is the shared fixture''s (the device asserts the same)');

select is_empty(
  $$ select b from fx, jsonb_array_elements_text(fx.j->'otp') b where not private.sms_is_otp(b) $$,
  'every OTP in the fixture is caught');

select is_empty(
  $$ select b from fx, jsonb_array_elements_text(fx.j->'not_otp') b where private.sms_is_otp(b) $$,
  'no transaction or other non-OTP message in the fixture is caught');

select is_empty(
  $$ select t.bank_code, t.name, e->>'body'
     from public.sms_templates t, jsonb_array_elements(t.examples) e
     where t.msg_kind <> 'other' and private.sms_is_otp(e->>'body') $$,
  'no purchase, refund, payment, declined, reversal or debit-card template example is an OTP');

select is_empty(
  $$ select distinct e->>'body'
     from public.sms_templates t, jsonb_array_elements(t.examples) e
     except
     select b from fx, jsonb_array_elements_text(fx.j->'otp') b
     except
     select b from fx, jsonb_array_elements_text(fx.j->'not_otp') b $$,
  'every sms_templates example body is in the shared fixture, so the device tests it too');

select ok(not private.sms_is_otp(null) and not private.sms_is_otp(''), 'empty input is not an OTP');

-- ── end to end: ingest_sms refuses an OTP and keeps the purchase ────────────
create temp table k (name text primary key, v text);
grant all on k to authenticated;
create function pg_temp.v(p text) returns text language sql as $$ select v from k where name = p $$;
create function pg_temp.set(p text, val text) returns text language sql as $$
  insert into k values (p, val) on conflict (name) do update set v = excluded.v returning v $$;
select pg_temp.set('uid', gen_random_uuid()::text);
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values (pg_temp.v('uid')::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        't38-' || pg_temp.v('uid') || '@test.dev', '{}', '{}', now(), now());
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.v('uid'), 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.set('p', public.create_profile('t38-' || left(pg_temp.v('uid'), 8), 'OTP filter'));
select pg_temp.set('res', public.ingest_sms(pg_temp.v('p'), jsonb_build_array(
  jsonb_build_object('client_msg_id', gen_random_uuid(), 'received_at', now(), 'sender', 'ENBD',
    'body', 'Use 482913 as the code to complete your purchase of AED 99.00 at AMAZON.AE with your Credit Card ending 9219. Never share this code.'),
  jsonb_build_object('client_msg_id', gen_random_uuid(), 'received_at', now(), 'sender', 'ADCBAlert',
    'body', 'Your authentication code for Credit Card XX9208 transaction of AED 20.00 is 552211'),
  jsonb_build_object('client_msg_id', gen_random_uuid(), 'received_at', '2026-09-09T04:05:00+04:00', 'sender', 'FAB',
    'body', 'Purchase of USD 20.00 at CODEFORGE.IO with Credit Card ending 7310 on 09/09/2026 04:00. Available limit AED 40,010.00')
))::text);
reset role;
select set_config('request.jwt.claims', '', true);

select is((select array_agg(r->>'status' order by ord) from jsonb_array_elements(pg_temp.v('res')::jsonb) with ordinality x(r, ord))[1:2],
          array['rejected_otp', 'rejected_otp'], 'ingest_sms rejects the OTP wordings the device used to let through');
select isnt((pg_temp.v('res')::jsonb -> 2 ->> 'status'), 'rejected_otp', 'the CODEFORGE.IO purchase is not taken for an OTP');
select is((select count(*)::int from public.sms_messages where profile_code = pg_temp.v('p')), 1,
          'only the purchase is stored');

select * from finish();
rollback;
