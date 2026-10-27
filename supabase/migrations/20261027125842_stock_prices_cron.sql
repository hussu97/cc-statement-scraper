-- Structured notes (20261027124257): the stock-prices function stores the day's closes of every
-- share a note follows and settles the notes. After the US close, Monday to Saturday UTC
-- (Saturday 22:30 UTC picks up a Friday close Yahoo revised).
select cron.schedule('ledger-stock-prices', '30 22 * * 1-6', $$select private.invoke_edge('stock-prices')$$);
