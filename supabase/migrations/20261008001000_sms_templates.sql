-- Real bank SMS formats (ADCB, FAB, Emirates NBD, SIB), captured from live
-- alerts. Two kinds of template:
--   * transactions (priority 10–50): purchase / refund / declined. These carry an
--     amount and feed the matcher.
--   * known non-transaction alerts (priority 900+): approval prompts, billing and
--     due reminders, statements, rewards, logins, account and debit-card alerts.
--     They are classified as 'other' / 'debit_card' so process_sms marks them
--     'ignored' instead of 'unparsed' (which would trigger the LLM fallback).
--     They are deliberately specific: an unknown format must still be 'unparsed'.
--
-- Non-transaction alerts often have no amount, so an amount is now required only
-- for the transaction kinds.

-- ── amount is required only for transaction kinds ───────────────────────────
alter table public.sms_templates drop constraint if exists sms_templates_field_groups_check;
alter table public.sms_templates add constraint sms_templates_amount_required_check
  check (msg_kind not in ('purchase', 'preauth', 'refund', 'reversal', 'payment') or field_groups ? 'amount');

-- Apply one template to a message. Returns null when the template doesn't match.
-- The returned jsonb holds normalized fields: amount, currency, merchant, last4,
-- date (ISO), time, available. Transaction kinds must yield an amount; other
-- kinds (alerts that are only classified and ignored) may yield no fields at all.
create or replace function private.apply_sms_template(t public.sms_templates, p_sender text, p_body text)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  m text[];
  f jsonb := '{}'::jsonb;
  k text;
  g int;
  v text;
begin
  if p_sender !~* t.sender_pattern then
    return null;
  end if;
  m := regexp_match(p_body, t.body_pattern, 'i');
  if m is null then
    return null;
  end if;
  for k, g in select key, value::int from jsonb_each_text(t.field_groups) loop
    v := btrim(m[g]);
    if v is null or v = '' then
      continue;
    end if;
    case k
      when 'amount', 'available' then
        f := f || jsonb_build_object(k, private.parse_amount(v)::text);
      when 'currency' then
        f := f || jsonb_build_object(k, upper(v));
      when 'merchant' then
        f := f || jsonb_build_object(k, private.normalize_text(v));
      when 'last4' then
        f := f || jsonb_build_object(k, right(regexp_replace(v, '[^0-9]', '', 'g'), 4));
      when 'date' then
        f := f || jsonb_build_object(k, to_char(to_date(v, coalesce(t.date_format, 'DD/MM/YYYY')), 'YYYY-MM-DD'));
      else
        f := f || jsonb_build_object(k, v);
    end case;
  end loop;
  if t.msg_kind in ('purchase', 'preauth', 'refund', 'reversal', 'payment') and f->>'amount' is null then
    return null;
  end if;
  return f;
end;
$$;

-- ── real sender ids (guarded: only rows still holding the original seed) ────
update public.banks set sms_senders = array['ADCBAlert']
  where bank_code = 'ADCB' and sms_senders = array['ADCB', 'ADCBAlert'];
update public.banks set sms_senders = array['FAB']
  where bank_code = 'FAB' and sms_senders = array['FAB', 'FABBANK'];
update public.banks set sms_senders = array['EmiratesNBD']
  where bank_code = 'ENBD' and sms_senders = array['EmiratesNBD', 'ENBD'];
update public.banks set sms_senders = array['SIB']
  where bank_code = 'SIB' and sms_senders = array['SIB', 'SIBank'];

-- ── templates ───────────────────────────────────────────────────────────────
-- private.validate_sms_template() proves every example parses to its `expect`.
-- Inserted only when a template of the same bank + name is absent.
insert into public.sms_templates (bank_code, name, sender_pattern, body_pattern, field_groups, date_format,
                                  msg_kind, priority, examples, source)
select v.bank_code, v.name, v.sender_pattern, v.body_pattern, v.field_groups::jsonb, v.date_format,
       v.msg_kind, v.priority, v.examples::jsonb, 'seed'
from (values
 -- ── ADCB ──────────────────────────────────────────────────────────────────
 ('ADCB', 'ADCB credit card purchase (Cr.Card)', '^ADCB',
  'Cr\.Card X+([0-9]{4}) was used for ([A-Z]{3}) ?([0-9,]+\.[0-9]{2}) on ([0-9]{2}/[0-9]{2}/[0-9]{4}) ([0-9]{2}:[0-9]{2}(?::[0-9]{2})?) at (.+)\. Avl\.? ?Cr\.? ?limit is ([A-Z]{3}) ?([0-9,]+\.[0-9]{2})',
  '{"last4":1,"currency":2,"amount":3,"date":4,"time":5,"merchant":6,"available":8}', 'DD/MM/YYYY', 'purchase', 10,
  '[{"sender":"ADCBAlert","body":"Your Cr.Card XXX9208 was used for AED46.00 on 09/08/2026 13:43:40 at Vox Cinemas,Dubai-AE. Avl. Cr.limit is AED26953.75",
     "expect":{"amount":"46.00","currency":"AED","last4":"9208","merchant":"VOX CINEMAS,DUBAI-AE","date":"2026-08-09","time":"13:43:40","available":"26953.75"}}]'),
 ('ADCB', 'ADCB credit card purchase (Credit Card)', '^ADCB',
  'Credit Card X+([0-9]{4}) was used for ([A-Z]{3}) ?([0-9,]+\.[0-9]{2}) on ([0-9]{2}/[0-9]{2}/[0-9]{4}) ([0-9]{2}:[0-9]{2}(?::[0-9]{2})?) at (.+)\. Available limit:? *([A-Z]{3}) ?([0-9,]+\.[0-9]{2})',
  '{"last4":1,"currency":2,"amount":3,"date":4,"time":5,"merchant":6,"available":8}', 'DD/MM/YYYY', 'purchase', 10,
  '[{"sender":"ADCBAlert","body":"Credit Card XX9208 was used for EGP69.94 on 09/09/2026 11:44:55 at UBER *TRIP HELP.UBER, help.uber.com-NL. Available limit  AED19965.95",
     "expect":{"amount":"69.94","currency":"EGP","last4":"9208","merchant":"UBER *TRIP HELP.UBER, HELP.UBER.COM-NL","date":"2026-09-09","time":"11:44:55","available":"19965.95"}},
    {"sender":"ADCBAlert","body":"Credit Card XX9208 was used for INR840.96 on 06/10/2026 12:43:13 at UBER * PENDING, help.uber.com-NL. Available limit AED26967.39",
     "expect":{"amount":"840.96","currency":"INR","last4":"9208","merchant":"UBER * PENDING, HELP.UBER.COM-NL","date":"2026-10-06","time":"12:43:13","available":"26967.39"}}]'),
 ('ADCB', 'ADCB card approval prompt (ignored)', '^ADCB',
  'approve your transaction at (.+) for ([A-Z]{3}) ?([0-9,]+\.[0-9]{2}) on your ADCB Card X+([0-9]{4})',
  '{"merchant":1,"currency":2,"amount":3,"last4":4}', null, 'other', 900,
  '[{"sender":"ADCBAlert","body":"Review your transaction\nTap to approve your transaction at Vox Cinemas for AED46.00 on your ADCB Card XXX9208, valid for 10 minutes. If not initiated by you, please deny and call +971600502030",
     "expect":{"amount":"46.00","currency":"AED","last4":"9208","merchant":"VOX CINEMAS"}}]'),
 ('ADCB', 'ADCB account credit/debit (ignored)', '^ADCB',
  '(?:Cr|Dr)\. transaction of ([A-Z]{3}) ?([0-9,]+\.[0-9]{2}) on your account number X+[0-9]+',
  '{"currency":1,"amount":2}', null, 'debit_card', 900,
  '[{"sender":"ADCBAlert","body":"A Cr. transaction of AED 1100.00 on your account number XXX310001 was successful.Available balance is 1105.04.",
     "expect":{"amount":"1100.00","currency":"AED"}}]'),
 ('ADCB', 'ADCB debit card purchase (ignored)', '^ADCB',
  'Debit card X+([0-9]{4}) linked to acc\. X+[0-9]+ used for ([A-Z]{3}) ?([0-9,]+\.[0-9]{2})(?: \([^)]*\))? on ([A-Z]{3} [0-9]{1,2} [0-9]{4}) +([0-9]{1,2}:[0-9]{2} ?[AP]M) at (.+)\. Avl\.? ?Bal ([A-Z]{3}) ?([0-9,]+\.[0-9]{2})',
  '{"last4":1,"currency":2,"amount":3,"date":4,"time":5,"merchant":6,"available":8}', 'Mon DD YYYY', 'debit_card', 900,
  '[{"sender":"ADCBAlert","body":"Debit card XXX9211 linked to acc. XXX320001 used for AED3.50 (+2.49% foreign txn fee) on Sep 11 2026  4:33PM at GOOGLEYOUTUBE M,US. Avl.Bal AED 51.54.",
     "expect":{"amount":"3.50","currency":"AED","last4":"9211","merchant":"GOOGLEYOUTUBE M,US","date":"2026-09-11","time":"4:33PM","available":"51.54"}}]'),
 ('ADCB', 'ADCB debit card alert (ignored, catch-all)', '^ADCB',
  'Debit card X+([0-9]{4}) linked to acc',
  '{"last4":1}', null, 'debit_card', 950,
  '[{"sender":"ADCBAlert","body":"Debit card XXX9211 linked to acc. XXX320001 used for AED3.50 (+2.49% foreign txn fee) on Sep 11 2026  4:33PM at GOOGLEYOUTUBE M,US. Avl.Bal AED 51.54.",
     "expect":{"last4":"9211"}}]'),
 ('ADCB', 'ADCB credit card billing alert (ignored)', '^ADCB',
  'Card X+([0-9]{4}) Billing alert',
  '{"last4":1}', null, 'other', 900,
  '[{"sender":"ADCBAlert","body":"Cr.Card XXX9208 Billing alert: Total due to avoid fin. charges: AED172.09. Due date Sep 18 2026; Pay min. AED100.00 by due date to avoid AED241.50 late fee",
     "expect":{"last4":"9208"}}]'),
 ('ADCB', 'ADCB TouchPoints redemption (ignored)', '^ADCB',
  'request to redeem TPs [0-9,]+ at (.+) was successful',
  '{"merchant":1}', null, 'other', 900,
  '[{"sender":"ADCBAlert","body":"Your request to redeem TPs 5500 at Noon Food was successful on 22/09/2026 18:10:01. TPs balance: 265. Earn more with the TouchPoints app: adcb.com/tpapp",
     "expect":{"merchant":"NOON FOOD"}}]'),
 ('ADCB', 'ADCB account dormancy notice (ignored)', '^ADCB',
  'account number X+[0-9]+ has been inactive since',
  '{}', null, 'other', 900,
  '[{"sender":"ADCBAlert","body":"Your account number XXX310001 has been inactive since 2026.01.31. Kindly make a transaction to avoid account from becoming dormant.",
     "expect":{}}]'),

 -- ── FAB (multi-line alerts) ───────────────────────────────────────────────
 ('FAB', 'FAB credit card purchase (multi-line)', '^FAB',
  'Credit Card Purchase\s*\n\s*Card No X*([0-9]{4})\s*\n\s*([A-Z]{3}) ?([0-9,]+\.[0-9]{2})\s*\n\s*([^\n]+)\n\s*([0-9]{2}/[0-9]{2}/[0-9]{2}) ([0-9]{2}:[0-9]{2})(?:\s*\n\s*Avl Bal ([A-Z]{3}) ?([0-9,]+\.[0-9]{2}))?',
  '{"last4":1,"currency":2,"amount":3,"merchant":4,"date":5,"time":6,"available":8}', 'DD/MM/YY', 'purchase', 10,
  '[{"sender":"FAB","body":"Credit Card Purchase\nCard No XXXX9206\nAED 133.96\nAPPLE.COM/BILL CORK IRL\n05/10/26 10:40\nAvl Bal AED 28335.60\nOctober statement due on 26/10/2026",
     "expect":{"amount":"133.96","currency":"AED","last4":"9206","merchant":"APPLE.COM/BILL CORK IRL","date":"2026-10-05","time":"10:40","available":"28335.60"}},
    {"sender":"FAB","body":"October statement due on 26/10/2026\nCredit Card Purchase\nCard No XXXX9203\nUSD 6.00\nINDIGO AIRLINES NEW YORK USA\n04/10/26 10:38",
     "expect":{"amount":"6.00","currency":"USD","last4":"9203","merchant":"INDIGO AIRLINES NEW YORK USA","date":"2026-10-04","time":"10:38"}}]'),
 ('FAB', 'FAB debit card purchase (ignored)', '^FAB',
  'Debit Card Purchase\s*\n\s*Card No X*([0-9]{4})\s*\n\s*([A-Z]{3}) ?([0-9,]+\.[0-9]{2})\s*\n\s*([^\n]+)\n\s*([0-9]{2}/[0-9]{2}/[0-9]{2}) ([0-9]{2}:[0-9]{2})',
  '{"last4":1,"currency":2,"amount":3,"merchant":4,"date":5,"time":6}', 'DD/MM/YY', 'debit_card', 900,
  '[{"sender":"FAB","body":"Debit Card Purchase\nCard No XXXX1234\nAED 20.00\nCARREFOUR DUBAI\n05/10/26 10:40\nAvl Bal AED 100.00",
     "expect":{"amount":"20.00","currency":"AED","last4":"1234","merchant":"CARREFOUR DUBAI","date":"2026-10-05","time":"10:40"}}]'),
 ('FAB', 'FAB outward remittance (ignored)', '^FAB',
  'Outward Remittance Debit\s*\n\s*Account X*[0-9]+\s*\n\s*([A-Z]{3}) ?([0-9,]+\.[0-9]{2})\s*\n\s*Date ([0-9]{2}/[0-9]{2}/[0-9]{4})',
  '{"currency":1,"amount":2,"date":3}', 'DD/MM/YYYY', 'debit_card', 900,
  '[{"sender":"FAB","body":"Outward Remittance Debit\nAccount XXXX9221\nAED 2100.00\nDate 02/10/2026\nBalance AED 3644.98",
     "expect":{"amount":"2100.00","currency":"AED","date":"2026-10-02"}}]'),
 ('FAB', 'FAB account alert (ignored, catch-all)', '^FAB',
  '\nAccount X+[0-9]{4}\s*\n',
  '{}', null, 'debit_card', 950,
  '[{"sender":"FAB","body":"Outward Remittance Debit\nAccount XXXX9221\nAED 2100.00\nDate 02/10/2026\nBalance AED 3644.98",
     "expect":{}}]'),
 ('FAB', 'FAB funds transfer (ignored)', '^FAB',
  'funds transfer request of +([A-Z]{3}) ?([0-9,]+\.[0-9]{2}) to .+ has been processed successfully.* on ([0-9]{2}/[0-9]{2}/[0-9]{4}) ([0-9]{2}:[0-9]{2})',
  '{"currency":1,"amount":2,"date":3,"time":4}', 'DD/MM/YYYY', 'other', 900,
  '[{"sender":"FAB","body":"Dear Customer, your funds transfer request of  AED 2,100.00 to IBAN/Account/Card XXXX9209  has been processed successfully from your account/ card XXXX9221 on 02/10/2026 14:19",
     "expect":{"amount":"2100.00","currency":"AED","date":"2026-10-02","time":"14:19"}}]'),
 ('FAB', 'FAB statement issued (ignored)', '^FAB',
  'statement of the card ending with ([0-9]{4})',
  '{"last4":1}', null, 'other', 900,
  '[{"sender":"FAB","body":"Your statement of the card ending with 9206 dated 01Oct26 has been sent to you and can also be viewed in the new FAB mobile banking app. Download it from the App Store https://apple.co/FB7qEZ or Google Play https://goo.gl/7dXnNc. The total amount due is AED 515.26. Minimum due is AED 100.00. Due date is 26Oct26",
     "expect":{"last4":"9206"}}]'),
 ('FAB', 'FAB login notice (ignored)', '^FAB',
  'Login detected on FAB',
  '{}', null, 'other', 900,
  '[{"sender":"FAB","body":"Login detected on FAB Mobile","expect":{}}]'),

 -- ── Emirates NBD ──────────────────────────────────────────────────────────
 ('ENBD', 'ENBD credit card purchase', '^EmiratesNBD',
  'Purchase of ([A-Z]{3}) ?([0-9,]+\.[0-9]{2}) with Credit Card ending ([0-9]{4}) at (.+)\. Avl\.? ?Cr\.? ?Limit is ([A-Z]{3}) ?([0-9,]+\.[0-9]{2})',
  '{"currency":1,"amount":2,"last4":3,"merchant":4,"available":6}', null, 'purchase', 10,
  '[{"sender":"EmiratesNBD","body":"Purchase of AED 73.69 with Credit Card ending 9219 at Noon Minutes, Dubai. Avl Cr. Limit is AED 19,626.23",
     "expect":{"amount":"73.69","currency":"AED","last4":"9219","merchant":"NOON MINUTES, DUBAI","available":"19626.23"}}]'),
 ('ENBD', 'ENBD credit card merchant payment', '^EmiratesNBD',
  'Payment of ([A-Z]{3}) ?([0-9,]+\.[0-9]{2}) to (.+) with Credit Card ending ([0-9]{4})\. Avl\.? ?Cr\.? ?Limit is ([A-Z]{3}) ?([0-9,]+\.[0-9]{2})',
  '{"currency":1,"amount":2,"merchant":3,"last4":4,"available":6}', null, 'purchase', 20,
  '[{"sender":"EmiratesNBD","body":"Payment of AED 42.00 to Noon with Credit Card ending 9219. Avl Cr. Limit is AED 19,951.23.",
     "expect":{"amount":"42.00","currency":"AED","last4":"9219","merchant":"NOON","available":"19951.23"}},
    {"sender":"EmiratesNBD","body":"Payment of AED 12.50 to noon one with Credit Card ending 9219. Avl Cr. Limit is AED 19,938.73.",
     "expect":{"amount":"12.50","currency":"AED","last4":"9219","merchant":"NOON ONE","available":"19938.73"}}]'),
 ('ENBD', 'ENBD credit card refund', '^EmiratesNBD',
  'Amount of ([A-Z]{3}) ?([0-9,]+\.[0-9]{2}) from (.+) has been credited to your card ending with ([0-9]{4})\. Available limit is ([A-Z]{3}) ?([0-9,]+\.[0-9]{2})',
  '{"currency":1,"amount":2,"merchant":3,"last4":4,"available":6}', null, 'refund', 20,
  '[{"sender":"EmiratesNBD","body":"Amount of AED 91.00 from NAMSHI has been credited to your card ending with 9219. Available limit is AED 19,532.39.",
     "expect":{"amount":"91.00","currency":"AED","last4":"9219","merchant":"NAMSHI","available":"19532.39"}}]'),
 ('ENBD', 'ENBD credit card mini statement (ignored)', '^EmiratesNBD',
  'Credit Card Mini Stmt for Card ending ([0-9]{4})',
  '{"last4":1}', null, 'other', 900,
  '[{"sender":"EmiratesNBD","body":"Emirates NBD Credit Card Mini Stmt for Card ending 9219: Statement date 28/08/26. Total Amt Due AED 48.77, Due Date 22/09/26. Min Amt Due AED 48.77",
     "expect":{"last4":"9219"}}]'),
 ('ENBD', 'ENBD credit card due reminder (ignored)', '^EmiratesNBD',
  'Payment for Credit Card ending ([0-9]{4}) is due on',
  '{"last4":1}', null, 'other', 900,
  '[{"sender":"EmiratesNBD","body":"Payment for Credit Card ending 9219 is due on 22/09/26. Total Amt - AED 48.77; Min Amt - AED 48.77. Please pay by due date to avoid charges.",
     "expect":{"last4":"9219"}}]'),
 ('ENBD', 'ENBD payment confirmation prompt (ignored)', '^EmiratesNBD',
  'payment on your card needs confirmation',
  '{}', null, 'other', 900,
  '[{"sender":"EmiratesNBD","body":"A payment on your card needs confirmation. Please check your Emirates NBD app.","expect":{}}]'),
 ('ENBD', 'ENBD login notice (ignored)', '^EmiratesNBD',
  'new login to (?:Mobile|Online)',
  '{}', null, 'other', 900,
  '[{"sender":"EmiratesNBD","body":"A new login to Mobile/Online Banking has been authorised on your device.","expect":{}}]'),

 -- ── SIB ───────────────────────────────────────────────────────────────────
 ('SIB', 'SIB covered card purchase', '^SIB',
  'txn on your (?:Covered|Credit) Card X*([0-9]{4}) at (.+) for ([A-Z]{3}) ?([0-9,]+\.[0-9]{2}) on ([0-9]{2}-[0-9]{2}-[0-9]{4}) ([0-9]{2}:[0-9]{2}) is approved(?:\. Your available balance is ([A-Z]{3}) ?([0-9,]+\.[0-9]{2}))?',
  '{"last4":1,"merchant":2,"currency":3,"amount":4,"date":5,"time":6,"available":8}', 'DD-MM-YYYY', 'purchase', 10,
  '[{"sender":"SIB","body":"A txn on your Covered Card XXXX9213 at Tesla Motors Netherlan for AED 52.91 on 02-10-2026 12:19 is approved. Your available balance is AED 7,459.22",
     "expect":{"amount":"52.91","currency":"AED","last4":"9213","merchant":"TESLA MOTORS NETHERLAN","date":"2026-10-02","time":"12:19","available":"7459.22"}},
    {"sender":"SIB","body":"A txn on your Covered Card XXXX9213 at EMIRATES for INR 28,400.00 on 02-10-2026 09:36 is approved. Your available balance is AED 7,512.13",
     "expect":{"amount":"28400.00","currency":"INR","last4":"9213","merchant":"EMIRATES","date":"2026-10-02","time":"09:36","available":"7512.13"}},
    {"sender":"SIB","body":"A txn on your Covered Card XXXX9213 at NOQ*Ejari for AED 177.75 on 03-10-2026 14:36 is approved. Your available balance is AED 7,241.47",
     "expect":{"amount":"177.75","currency":"AED","last4":"9213","merchant":"NOQ*EJARI","date":"2026-10-03","time":"14:36","available":"7241.47"}},
    {"sender":"SIB","body":"A txn on your Covered Card XXXX9213 at INTEGRATED GAS SERVICE for AED 105.75 on 08-10-2026 11:23 is approved. Your available balance is AED 7,135.72",
     "expect":{"amount":"105.75","currency":"AED","last4":"9213","merchant":"INTEGRATED GAS SERVICE","date":"2026-10-08","time":"11:23","available":"7135.72"}}]'),
 -- Best effort: no real declined alert captured yet; the example follows the
 -- approved layout with "is declined".
 ('SIB', 'SIB covered card declined', '^SIB',
  'txn on your (?:Covered|Credit) Card X*([0-9]{4}) at (.+) for ([A-Z]{3}) ?([0-9,]+\.[0-9]{2}) on ([0-9]{2}-[0-9]{2}-[0-9]{4}) ([0-9]{2}:[0-9]{2}) is declined',
  '{"last4":1,"merchant":2,"currency":3,"amount":4,"date":5,"time":6}', 'DD-MM-YYYY', 'declined', 20,
  '[{"sender":"SIB","body":"A txn on your Covered Card XXXX9213 at Tesla Motors Netherlan for AED 1.00 on 02-10-2026 12:19 is declined. Your available balance is AED 7,459.22",
     "expect":{"amount":"1.00","currency":"AED","last4":"9213","merchant":"TESLA MOTORS NETHERLAN","date":"2026-10-02","time":"12:19"}}]'),
 ('SIB', 'SIB card activation notice (ignored)', '^SIB',
  'Thank you for activating your new SIB',
  '{}', null, 'other', 900,
  '[{"sender":"SIB","body":"Thank you for activating your new SIB Covered Card and accepting the updated Terms & Conditions. Your new card is now ready to use. Remember to update your card details across secure digital wallets and subscriptions. To view Terms & Conditions and Key Facts Statement, visit www.sib.ae/CSU",
     "expect":{}}]')
) as v(bank_code, name, sender_pattern, body_pattern, field_groups, date_format, msg_kind, priority, examples)
where not exists (select 1 from public.sms_templates s where s.bank_code = v.bank_code and s.name = v.name);
