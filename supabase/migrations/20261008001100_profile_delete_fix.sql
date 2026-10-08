-- Deleting a profile cascades into category_rules, whose statement trigger
-- bumped profile_state for the profile being deleted and hit its FK. Skip
-- profiles that no longer exist.
create or replace function private.bump_and_recategorize(p_profiles text[])
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  p text;
begin
  foreach p in array coalesce(p_profiles, '{}') loop
    continue when not exists (select 1 from public.profiles x where x.profile_code = p);
    insert into public.profile_state (profile_code, rules_version) values (p, 2)
    on conflict (profile_code) do update
      set rules_version = public.profile_state.rules_version + 1, updated_at = now();
    perform private.recategorize(p, null);
  end loop;
end;
$$;
