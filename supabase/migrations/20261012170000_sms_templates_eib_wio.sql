-- SMS templates for Emirates Islamic (sender "EI SMS") and Wio (sender "WioPersonal"),
-- from real alerts on 2026-10-12, plus an ENBD account-recovery notice. Same two kinds
-- as 20261008001000: transactions (priority 10) feed the matcher; known
-- non-transaction alerts (priority 900) are classified 'other' so they are stored
-- 'ignored' instead of 'unparsed' (which calls the LLM fallback). The ignored ones
-- stay specific so an unknown format is still 'unparsed'.
--
-- Wio prints no date or time: process_sms then dates the transaction at received_at,
-- which for an alert is within seconds of the charge. Wio amounts may have no
-- decimals ("AED 650"). Only "with Credit money" is a card purchase; a Wio alert paid
-- from another balance has no sample yet and stays 'unparsed'.
--
-- Content migration, guarded (CLAUDE.md §1.9): templates are inserted when no template
-- of the same bank + name exists; sender ids are updated only from their seeded value.
-- Inserting active templates re-processes the matching senders' recent messages
-- (private.trg_sms_templates_reprocess, DB-22), so alerts already captured as
-- 'unparsed' are classified now.

update public.banks set sms_senders = array['EI SMS']
  where bank_code = 'EIB' and sms_senders = array['EI', 'EIBank', 'EmiratesIsl'];
update public.banks set sms_senders = array['WioPersonal']
  where bank_code = 'WIO' and sms_senders = '{}';

insert into public.sms_templates (bank_code, name, sender_pattern, body_pattern, field_groups, date_format,
                                  msg_kind, priority, examples, source)
select v.bank_code, v.name, v.sender_pattern, v.body_pattern, v.field_groups::jsonb, v.date_format,
       v.msg_kind, v.priority, v.examples::jsonb, 'seed'
from (values
 -- ── Emirates Islamic ──────────────────────────────────────────────────────
 ('EIB', 'EIB credit card purchase (multi-line)', '^(EI ?SMS|EIBank|EmiratesIsl)',
  'Credit Card Purchase\s*\n\s*Card Ending:? *X*([0-9]{4})\s*\n\s*At:? *([^\n]+)\n\s*Amount:? *([A-Z]{3}) ?([0-9,]+(?:\.[0-9]{1,2})?)\s*\n\s*Date:? *([0-9]{2}/[0-9]{2}/[0-9]{4}),? *([0-9]{2}:[0-9]{2})(?:\s*\n\s*Available Limit:? *([A-Z]{3}) ?([0-9,]+\.[0-9]{2}))?',
  '{"last4":1,"merchant":2,"currency":3,"amount":4,"date":5,"time":6,"available":8}', 'DD/MM/YYYY', 'purchase', 10,
  '[{"sender":"EI SMS","body":"Credit Card Purchase\nCard Ending: 4557\nAt: NATIONAL TAXI, DUBAI\nAmount: AED 59.50\nDate: 16/09/2026, 12:14\nAvailable Limit: AED 36,957.01",
     "expect":{"amount":"59.50","currency":"AED","last4":"4557","merchant":"NATIONAL TAXI, DUBAI","date":"2026-09-16","time":"12:14","available":"36957.01"}}]'),
 ('EIB', 'EIB credit card mini statement (ignored)', '^(EI ?SMS|EIBank|EmiratesIsl)',
  'Credit Card Mini Statement\s*\n\s*Card Starting:? *[0-9]{6}', '{}', null, 'other', 900,
  '[{"sender":"EI SMS","body":"Credit Card Mini Statement\nCard Starting: 457828\nStatement Date: 10/10/2026\nMinimum Amount Due: AED 229.45\nAmount to be paid to avoid charges:  AED 4,589.03\nDue Date: 04/11/2026\nPlease pay on or before due date to avoid commitment to donate amount.","expect":{}}]'),
 ('EIB', 'EIB wallet enrolment notice (ignored)', '^(EI ?SMS|EIBank|EmiratesIsl)',
  '(card ending [0-9]{4} has been (enrolled into|disabled from) [A-Za-z ]*Wallet|to complete adding your card ending [0-9]{4} to the digital wallet)',
  '{}', null, 'other', 900,
  '[{"sender":"EI SMS","body":"Dear Customer, your card ending 4557 has been enrolled into Apple Wallet. If you did not initiate this, please call 600599995","expect":{}},
    {"sender":"EI SMS","body":"Dear Customer, your card ending 4557 has been disabled from Apple Wallet. If you did not initiate this transaction, please call 600599995","expect":{}},
    {"sender":"EI SMS","body":"Dear Customer, to complete adding your card ending 4557 to the digital wallet, retrieve the OTP from the EI + App. If you don’t have the app, please download and register to view the OTP. Do not share your OTP !","expect":{}}]'),
 ('EIB', 'EIB mobile banking access notice (ignored)', '^(EI ?SMS|EIBank|EmiratesIsl)',
  '(activated Smart Pass on your trusted device|Smart Pass has been deactivated|regained access to your EI\+ Mobile|retrieval request is pending your authori[sz]ation)',
  '{}', null, 'other', 900,
  '[{"sender":"EI SMS","body":"Dear Customer, you have successfully activated Smart Pass on your trusted device for your Mobile and Online Banking. If this wasn''t you, please call +971 600 59 9995 and report fraud.","expect":{}},
    {"sender":"EI SMS","body":"Dear Customer, Your Smart Pass has been deactivated from your old device, please continue transacting on the new device.","expect":{}},
    {"sender":"EI SMS","body":"Dear Customer, you have regained access to your EI+ Mobile/Online banking successfully. If this wasn''t you, please call +971 600 599995 and report fraud.","expect":{}},
    {"sender":"EI SMS","body":"Your Username retrieval request is pending your authorisation.","expect":{}}]'),

 -- ── Wio ───────────────────────────────────────────────────────────────────
 ('WIO', 'Wio credit card payment', '^Wio',
  'Payment of ([A-Z]{3}) ?([0-9,]+(?:\.[0-9]{1,2})?) was done at (.+?) using your Wio [A-Za-z ]*card (?:ending (?:with )?)?([0-9]{4}) with Credit money',
  '{"currency":1,"amount":2,"merchant":3,"last4":4}', null, 'purchase', 10,
  '[{"sender":"WioPersonal","body":"Payment of AED 593.03 was done at Dubai Electricity using your Wio Personal card 2010 with Credit money",
     "expect":{"amount":"593.03","currency":"AED","last4":"2010","merchant":"DUBAI ELECTRICITY"}},
    {"sender":"WioPersonal","body":"Payment of AED 650 was done at Dubai Duty Free using your Wio Personal card 2010 with Credit money",
     "expect":{"amount":"650.00","currency":"AED","last4":"2010","merchant":"DUBAI DUTY FREE"}}]'),
 ('WIO', 'Wio wallet notice (ignored)', '^Wio',
  'card ending (?:with )?[0-9]{4} has been added to [A-Za-z ]*Pay', '{}', null, 'other', 900,
  '[{"sender":"WioPersonal","body":"Your Wio Personal card ending with 2010 has been added to Apple Pay. If it wasn''t you, freeze this card in the App and contact us immediately at 600 500 946","expect":{}}]'),

 -- ── Emirates NBD ──────────────────────────────────────────────────────────
 ('ENBD', 'ENBD account recovery notice (ignored)', '^EmiratesNBD',
  'request to recover access to your ENBD X profile', '{}', null, 'other', 900,
  '[{"sender":"EmiratesNBD","body":"Dear Customer, you''ve initiated a request to recover access to your ENBD X profile. If this wasn''t you, please call +971 600 54 0000 and report fraud.","expect":{}}]')
) as v(bank_code, name, sender_pattern, body_pattern, field_groups, date_format, msg_kind, priority, examples)
where not exists (select 1 from public.sms_templates t where t.bank_code = v.bank_code and t.name = v.name);
