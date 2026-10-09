-- ledger-llm-enqueue moves from 22:30 UTC (02:30 Dubai) to 18:00 UTC (22:00 Dubai), the
-- owner's choice, so the day's new merchants are categorised the same evening.
-- cron.schedule with an existing job name updates that job in place.
select cron.schedule('ledger-llm-enqueue', '0 18 * * *', $$select private.enqueue_llm_categorize()$$);
