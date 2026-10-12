-- Wio Bank (Wio Personal credit card): reference data for the parser's new WIO layout
-- (services/parser/ccs_parser/banks/wio.py, parser 2026.10.11).
--
-- Statements arrive by email from communications@mail.wio.io ("Your Wio Credit statement for
-- this month"), unencrypted, so no WIO_PDF_PASSWORD exists. No SMS sender is seeded: Wio
-- alerts are app notifications, and an unconfirmed sender id would attribute other messages.
--
-- FX: a foreign purchase is billed in AED at the scheme rate ("Rate: 3.70 (AED/USD)" against
-- the 3.6725 peg: +0.75%) and Wio's 2% fee is its own "Foreign Exchange Fee" row (1.48 on
-- 74.00, 14.30 on 715.04). The estimate covers the purchase row only, so the markup is the
-- scheme part alone. Wio prints no foreign amount, so its lines never teach a statement rate.

-- Content seed, guarded (CLAUDE.md §1.9): insert when absent.
insert into public.banks (bank_code, name, sms_senders, logo_path)
values ('WIO', 'Wio Bank', '{}', 'WIO.png')
on conflict (bank_code) do nothing;

insert into private.bank_fx_fees (bank_code, markup, note)
values ('WIO', 0.007500,
        'scheme rate only (AED/USD 3.70 vs 3.6725 peg); the 2% FX fee is a separate statement row')
on conflict (bank_code) do nothing;
