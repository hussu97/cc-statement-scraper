-- SIB SMS formats the templates missed (2026-10-30). SIB's alerts come in two systems: the one
-- before its card-system update ("A txn on your Card XXXX… for AED  12.50 on 05-Aug at 19:42  is
-- approved. Your available balance is 4821.30", no year) and the one after ("… on 03-10-2026
-- 18:05 is approved. Your available balance is AED 6,912.40"), which prints "Card" alone as well
-- as "Covered Card". Payment confirmations carry a doubled space and no final period.
--
-- 1. SIB covered card purchase also takes a plain "Card" (guarded: only the seeded pattern).
-- 2. New templates: the older purchase alert (no year, so its time is the SMS's own, which
--    arrives with the purchase); the payment credit and the cashback credit for any spacing; and,
--    ignored, a zero-amount card check, a failed attempt, the older due reminder (no year) and
--    card notices (activation, Apple Pay, PIN, system update).
-- Content migration (§1.9): inserts only when absent.

update public.sms_templates
set body_pattern = 'txn on your (?:(?:Covered|Credit) )?Card X*([0-9]{4}) at (.+) for ([A-Z]{3}) ?([0-9,]+\.[0-9]{2}) on ([0-9]{2}-[0-9]{2}-[0-9]{4}) ([0-9]{2}:[0-9]{2}) is approved(?:\. Your available balance is ([A-Z]{3}) ?([0-9,]+\.[0-9]{2}))?',
    examples = examples || '[{"sender":"SIB","body":"A txn on your Card XXXX9213 at Tesla Motors Netherlan for AED 41.27 on 03-10-2026 18:05 is approved. Your available balance is AED 6,912.40",
      "expect":{"amount":"41.27","currency":"AED","last4":"9213","merchant":"TESLA MOTORS NETHERLAN","date":"2026-10-03","time":"18:05","available":"6912.40"}}]'::jsonb,
    version = version + 1,
    updated_at = now()
where bank_code = 'SIB' and name = 'SIB covered card purchase'
  and body_pattern = 'txn on your (?:Covered|Credit) Card X*([0-9]{4}) at (.+) for ([A-Z]{3}) ?([0-9,]+\.[0-9]{2}) on ([0-9]{2}-[0-9]{2}-[0-9]{4}) ([0-9]{2}:[0-9]{2}) is approved(?:\. Your available balance is ([A-Z]{3}) ?([0-9,]+\.[0-9]{2}))?';

insert into public.sms_templates (bank_code, name, sender_pattern, body_pattern, field_groups, date_format,
                                  msg_kind, priority, examples, source)
select v.bank_code, v.name, v.sender_pattern, v.body_pattern, v.field_groups::jsonb, v.date_format,
       v.msg_kind, v.priority, v.examples::jsonb, 'seed'
from (values
 ('SIB', 'SIB card zero-amount check (ignored)', '^SIB',
  'txn on your (?:(?:Covered|Credit) )?Card X*[0-9]{4} at .+ for [A-Z]{3} *0\.00 on ',
  '{}', null, 'other', 5,
  '[{"sender":"SIB","body":"A txn on your Card XXXX9214 at SAMPLE DELIVERY for AED  0.00 on 07-Aug at 10:15  is approved. Your available balance is 4821.30","expect":{}}]'),
 ('SIB', 'SIB card purchase (before the card-system update)', '^SIB',
  'txn on your Card X*([0-9]{4}) at (.+?) for ([A-Z]{3}) +([0-9,]+\.[0-9]{2}) on [0-9]{1,2}-[A-Za-z]{3} at [0-9]{2}:[0-9]{2} +is approved\. Your available balance is ([A-Z]{3} ?)?([0-9,]+\.[0-9]{2})',
  '{"last4":1,"merchant":2,"currency":3,"amount":4,"available":6}', null, 'purchase', 10,
  '[{"sender":"SIB","body":"A txn on your Card XXXX9214 at CORNER GROCERY for AED  12.50 on 05-Aug at 19:42  is approved. Your available balance is 4821.30",
     "expect":{"amount":"12.50","currency":"AED","last4":"9214","merchant":"CORNER GROCERY","available":"4821.30"}},
    {"sender":"SIB","body":"A txn on your Card XXXX9214 at Sample Hotel USD for USD  140.00 on 06-Aug at 21:10  is approved. Your available balance is 4306.80",
     "expect":{"amount":"140.00","currency":"USD","last4":"9214","merchant":"SAMPLE HOTEL USD","available":"4306.80"}}]'),
 ('SIB', 'SIB card payment credited', '^SIB',
  'Thank you for your payment against your +Card\. ([A-Z]{3}) ([0-9,]+(?:\.[0-9]+)?) has been credited to your card account X*([0-9]{4})',
  '{"currency":1,"amount":2,"last4":3}', null, 'payment', 20,
  '[{"sender":"SIB","body":"Thank you for your payment against your  Card. AED 1250.00 has been credited to your card account XXXX9214",
     "expect":{"currency":"AED","amount":"1250.00","last4":"9214"}}]'),
 ('SIB', 'SIB card cashback credited', '^SIB',
  'Total (Cashback) of ([A-Z]{3}) ([0-9,]+(?:\.[0-9]+)?) has been credited to your card ending with X*([0-9]{4})',
  '{"merchant":1,"currency":2,"amount":3,"last4":4}', null, 'refund', 20,
  '[{"sender":"SIB","body":"Total Cashback of AED 214.00 has been credited to your card ending with XXXX9214.",
     "expect":{"merchant":"CASHBACK","currency":"AED","amount":"214.00","last4":"9214"}}]'),
 ('SIB', 'SIB card notices (ignored)', '^SIB',
  '(txn attempt on Card\.? X*[0-9]{4} .* was not processed|payment is due on [0-9]{1,2}-[A-Za-z]{3},|new Covered Card X*[0-9]{4} has been activated|is ready for Apple Pay|time to activate your new SIB|Your Mobile Banking request for|as part of our card system update)',
  '{}', null, 'other', 900,
  '[{"sender":"SIB","body":"A txn attempt on Card. XXXX9214 at SAMPLE STORE for AED 0.00 on 04-10-2026 09:48 was not processed. For assistance call us on 600 000000","expect":{}},
    {"sender":"SIB","body":"Covered Card ending with XXXX9214 payment is due on 30-Aug, outstanding amount is AED 412.18, minimum payment due is AED 100.00. Ensure paying before 30-Aug to avoid deducting any amount under commitment to donate clause. Total Cashback points is 120","expect":{}},
    {"sender":"SIB","body":"Dear Customer, your new Covered Card XXXX9214 has been activated successfully, for info call 600 000000 or visit www.example.ae","expect":{}},
    {"sender":"SIB","body":"Your SIB card 400000XXXXXX9214 is ready for Apple Pay. You can use it wherever you see the contactless symbol or Apple Pay mark.","expect":{}},
    {"sender":"SIB","body":"It''s time to activate your new SIB Covered Card. Activate your card and set your PIN before 12 November 2026 through SIB Digital App, SIB ATM or by calling 600 000000.","expect":{}},
    {"sender":"SIB","body":"Your Mobile Banking request for Activate cards with set pin Failed on 04-10-26 at 09:49:19. Ref No: 1000001. You may apply via Phone Banking 600 000000 or visit your nearest branch.","expect":{}}]')
) as v(bank_code, name, sender_pattern, body_pattern, field_groups, date_format, msg_kind, priority, examples)
where not exists (select 1 from public.sms_templates s where s.bank_code = v.bank_code and s.name = v.name);
