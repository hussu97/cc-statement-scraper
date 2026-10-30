-- Wio SMS template examples use synthetic amounts (2026-10-30, CLAUDE.md §14.5). The examples
-- seeded by 20261020154502 and 20261020170933 carried real alert amounts with only the names
-- swapped; each is replaced by an unrelated amount (and the statement dates by another month).
-- Content migration (§1.9): only examples still holding the exact old text change.

update public.sms_templates
set examples = replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(
                 replace(replace(replace(examples::text,
                 'AED 468 ', 'AED 436 '), '"468.00"', '"436.00"'),
                 'AED 23,700 ', 'AED 21,450 '), '"23700.00"', '"21450.00"'),
                 'USD 15,000 ', 'USD 12,000 '), 'AED 55,162.50', 'AED 44,130.00'), '"55162.50"', '"44130.00"'),
                 'AED 19,082', 'AED 12,640'), '"19082.00"', '"12640.00"'),
                 'AED 205.33', 'AED 118.47'), '"205.33"', '"118.47"'),
                 'USD 2,000 (AED 7,400)', 'USD 1,500 (AED 5,550)'), '"7400.00"', '"5550.00"'),
                 'on 2026-09-30, and auto-pay runs at 9:00 PM on 2026-10-01',
                 'on 2026-06-30, and auto-pay runs at 9:00 PM on 2026-07-01'),
                 '"2026-09-30"', '"2026-06-30"')::jsonb,
    updated_at = now()
where bank_code = 'WIO'
  and examples::text ~ '(AED 468 |AED 23,700 |AED 55,162\.50|AED 19,082|AED 205\.33|\(AED 7,400\)|2026-09-30)';
