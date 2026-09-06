-- =====================================================================
-- Polls: let each poll decide single-choice vs multi-choice voting,
-- and enforce it at the DB level (not just in the UI).
--
-- poll_votes' primary key (poll_option_id, resident_id) only prevented
-- a resident from voting for the SAME option twice — nothing stopped
-- them from voting for several different options in the same poll.
-- =====================================================================

alter table polls add column allow_multiple_answers boolean not null default false;

-- Single-choice polls: a new vote replaces the resident's previous vote
-- in the same poll (common "change your vote" UX), rather than erroring
-- or silently allowing two options to be selected at once.
create or replace function enforce_single_choice_poll_vote() returns trigger as $$
declare
  v_poll_id uuid;
  v_allow_multiple boolean;
begin
  select po.poll_id, p.allow_multiple_answers
    into v_poll_id, v_allow_multiple
  from poll_options po
  join polls p on p.id = po.poll_id
  where po.id = new.poll_option_id;

  if not v_allow_multiple then
    delete from poll_votes
    where resident_id = new.resident_id
      and poll_option_id in (
        select id from poll_options where poll_id = v_poll_id
      )
      and poll_option_id <> new.poll_option_id;
  end if;

  return new;
end;
$$ language plpgsql;

create trigger trg_enforce_single_choice_poll_vote
  before insert on poll_votes
  for each row execute function enforce_single_choice_poll_vote();
