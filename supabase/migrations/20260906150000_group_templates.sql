-- =====================================================================
-- Group templates: a manager-selectable starter-group catalog, applied
-- per community via an explicit "initialize groups" action (not an
-- automatic trigger) — different communities may want a different mix.
-- =====================================================================

create table group_templates (
  id serial primary key,
  name text not null,
  interest_tag_id int references interest_tags(id),
  description text,
  is_active boolean not null default true,
  display_order int not null default 0
);

insert into group_templates (name, description, display_order) values
  ('לוח קח-תן', 'מקום לתת ולקבל חפצים בין שכנים', 1),
  ('אוהבי כלבים בשכונה', 'קבוצה לבעלי כלבים ואוהבי כלבים', 2),
  ('הורים לתינוקות', 'קבוצת תמיכה והחלפת מידע להורים טריים', 3);

alter table group_templates enable row level security;

-- Applying a template to a community creates a real row in `groups`
-- with created_by left NULL (an "official" starter group, not
-- attributed to a specific resident) — no schema change needed there,
-- groups.created_by is already nullable.
