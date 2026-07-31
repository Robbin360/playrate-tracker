-- ── Catálogo de categorías (géneros) ──
create table if not exists sorts (
  sort_id      text primary key,
  display_name text not null,
  first_seen   date not null default current_date,
  last_seen    date not null default current_date
);

-- ── Cada experiencia que vemos alguna vez ──
create table if not exists experiences (
  universe_id   bigint primary key,
  root_place_id bigint,
  name          text,
  creator_name  text,
  creator_id    bigint,
  created_at    timestamptz,
  first_seen    date not null default current_date,
  last_seen     date not null default current_date
);

-- ── Foto diaria de métricas. Una fila por juego por día. ──
create table if not exists snapshots (
  id           bigserial primary key,
  universe_id  bigint not null references experiences(universe_id) on delete cascade,
  captured_on  date   not null default current_date,
  visits       bigint,
  playing      integer,
  favorites    bigint,
  max_players  integer,
  game_updated timestamptz,
  unique (universe_id, captured_on)
);
create index if not exists snapshots_day  on snapshots(captured_on);
create index if not exists snapshots_univ on snapshots(universe_id);

-- ── En qué categoría y en qué posición apareció cada juego ──
create table if not exists placements (
  id          bigserial primary key,
  universe_id bigint not null references experiences(universe_id) on delete cascade,
  sort_id     text   not null,
  rank        integer not null,
  captured_on date   not null default current_date,
  unique (universe_id, sort_id, captured_on)
);
create index if not exists placements_sort on placements(sort_id, captured_on);

-- ── EL FOSO: cada versión distinta de cada imagen ──
-- La clave única sobre sha256 hace que solo se guarde cuando la imagen CAMBIÓ.
create table if not exists images (
  id            bigserial primary key,
  universe_id   bigint not null references experiences(universe_id) on delete cascade,
  kind          text   not null check (kind in ('thumbnail','icon')),
  sha256        text   not null,
  storage_path  text   not null,
  bytes         integer,
  first_seen_on date   not null default current_date,
  last_seen_on  date   not null default current_date,
  unique (universe_id, kind, sha256)
);
create index if not exists images_univ on images(universe_id, kind);

-- ── Registro de cada corrida, para saber si el cron se cayó ──
create table if not exists runs (
  id             bigserial primary key,
  started_at     timestamptz not null default now(),
  finished_at    timestamptz,
  sorts_seen     integer,
  universes_seen integer,
  images_new     integer,
  errors         integer,
  notes          text
);

-- ── Vista de crecimiento a 7 días: esto es lo que vende ──
create or replace view movers_7d as
with latest as (
  select universe_id, max(captured_on) as d from snapshots group by universe_id
),
now_ as (
  select s.universe_id, s.visits, s.playing, s.captured_on
  from snapshots s join latest l
    on l.universe_id = s.universe_id and l.d = s.captured_on
),
then_ as (
  select distinct on (s.universe_id)
         s.universe_id, s.visits as visits_then, s.captured_on as then_on
  from snapshots s join latest l on l.universe_id = s.universe_id
  where s.captured_on <= l.d - 7
  order by s.universe_id, s.captured_on desc
)
select e.universe_id,
       e.name,
       n.visits,
       n.playing,
       t.visits_then,
       n.visits - t.visits_then as visit_delta,
       round(100.0 * (n.visits - t.visits_then) / nullif(t.visits_then,0), 2) as pct_7d,
       t.then_on,
       n.captured_on
from now_ n
join then_ t using (universe_id)
join experiences e using (universe_id)
where t.visits_then > 0;
