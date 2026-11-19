-- 荒らし対策の追加設定。Supabase の SQL Editor に貼って Run（1回だけ）
alter table pins add column if not exists ip_hash text;
alter table pins add column if not exists floor text;

-- 公開用ビューに階を追加
create or replace view pins_public as
  select id,t,lat,lng,note,reports,created_at,floor from pins;

-- 通報の記録（1人1ピンにつき1回だけ数える）
create table if not exists reports(
  pin_id bigint not null references pins(id) on delete cascade,
  reporter text not null,
  primary key (pin_id, reporter)
);
alter table reports enable row level security;

-- 投稿者の識別キー（IPアドレスのハッシュ。無ければ端末のトークン）
create or replace function client_key(tok text) returns text
language sql stable as $$
  select md5(coalesce(nullif(split_part(coalesce(current_setting('request.headers', true)::json->>'x-forwarded-for',''), ',', 1), ''), tok))
$$;

-- 追加：1日30件まで、メモにリンクは不可、階は英数字4文字まで
drop function if exists add_pin(text,double precision,double precision,text,text);
drop function if exists add_pin(text,double precision,double precision,text,text,text);
create function add_pin(p_t text,p_lat double precision,p_lng double precision,p_note text,tok text,p_floor text default null)
returns bigint language plpgsql security definer set search_path=public as $$
declare k text := client_key(tok); n int; new_id bigint; fl text;
begin
  select count(*) into n from pins where ip_hash = k and created_at > now() - interval '1 day';
  if n >= 30 then raise exception 'too many pins today'; end if;
  if coalesce(p_note,'') ~* '(https?://|www\.|\.com|\.jp)' then raise exception 'links not allowed'; end if;
  fl := case when p_floor ~ '^[0-9A-Za-z]{1,4}$' then upper(p_floor) else null end;
  insert into pins(t,lat,lng,note,owner_token,ip_hash,floor)
    values(p_t,p_lat,p_lng,left(coalesce(p_note,''),100),tok,k,fl) returning id into new_id;
  return new_id;
end $$;
grant execute on function add_pin(text,double precision,double precision,text,text,text) to anon;

-- 報告：同じ人が何度押しても1回。3人で地図から非表示
drop function if exists report_pin(bigint);
create function report_pin(p_id bigint, tok text)
returns void language plpgsql security definer set search_path=public as $$
begin
  insert into reports(pin_id, reporter) values(p_id, client_key(tok)) on conflict do nothing;
  update pins set reports = (select count(*) from reports r where r.pin_id = p_id) where id = p_id;
end $$;
grant execute on function report_pin(bigint, text) to anon;
