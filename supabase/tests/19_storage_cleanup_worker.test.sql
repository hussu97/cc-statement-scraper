-- DB-21e (20261009100100_storage_cleanup_worker.sql): storage_cleanup has a DLQ, the
-- DLQ tools accept it, and kick_worker wakes the worker for it.
begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

select ok(exists (select 1 from pgmq.list_queues() where queue_name = 'storage_cleanup_dlq'),
          'storage_cleanup_dlq exists');
select ok(pg_get_functiondef('private.kick_worker()'::regprocedure) like '%q_storage_cleanup%',
          'kick_worker checks storage_cleanup for visible messages');

set local role service_role;
select lives_ok($$select public.drain_dlq('storage_cleanup')$$, 'drain_dlq accepts storage_cleanup');
reset role;
select pgmq.send('storage_cleanup_dlq', '{"bucket": "statements", "paths": ["prf_x/doc_y.pdf"], "attempt": 5}');
set local role service_role;
select is(public.requeue_dlq('storage_cleanup'), 1, 'requeue_dlq moves a storage_cleanup batch back');
select throws_ok($$select public.drain_dlq('storage_cleanup_typo')$$, '22023', null, 'unknown queues are still refused');
reset role;
select ok(exists (select 1 from pgmq.q_storage_cleanup where message ->> 'bucket' = 'statements'
                    and not message ? 'attempt'),
          'the requeued batch is on storage_cleanup with a fresh attempt count');

set local role authenticated;
select throws_ok($$select public.drain_dlq('storage_cleanup')$$, '42501', null, 'clients cannot drain DLQs');
reset role;

select * from finish();
rollback;
