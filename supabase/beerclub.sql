-- Beer Club · Ficoa Beer Garden
-- Todo vive en el schema "beerclub": no toca public ni ningún otro dato del proyecto.
-- Ejecutar completo en Supabase → SQL Editor.
-- Sin SMS ni proveedores externos: el cliente entra con celular + PIN de 4 dígitos y
-- guarda su tarjeta mandándose el enlace por WhatsApp (wa.me). El personal entra con email/clave de Supabase.
-- Si ya corriste una versión anterior, ejecuta primero:  drop schema if exists beerclub cascade;

create schema if not exists beerclub;

-- ─── Tablas ───────────────────────────────────────────────
create table if not exists beerclub.clientes (
  id              uuid primary key default gen_random_uuid(),
  telefono        text unique not null,           -- solo dígitos, con código de país: 593991234567
  pin_hash        text not null,
  intentos        int not null default 0,
  bloqueado_hasta timestamptz,
  nombre          text not null,
  fecha_nac       date,
  qr_token        text unique not null default replace(gen_random_uuid()::text,'-',''),
  referido_por    uuid references beerclub.clientes(id),
  acepta_whatsapp boolean not null default true,
  creado_en       timestamptz not null default now()
);

create table if not exists beerclub.staff (
  auth_id   uuid primary key references auth.users(id) on delete cascade,
  nombre    text not null,
  rol       text not null check (rol in ('mesero','admin')),
  activo    boolean not null default true
);

create table if not exists beerclub.movimientos (
  id           bigint generated always as identity primary key,
  cliente_id   uuid not null references beerclub.clientes(id),
  staff_id     uuid references beerclub.staff(auth_id),
  tipo         text not null check (tipo in ('compra','canje','bono','ajuste','vencimiento')),
  monto_compra numeric(10,2),
  puntos       integer not null,
  ref_ticket   text unique,
  nota         text,
  creado_en    timestamptz not null default now()
);
create index if not exists movimientos_cliente_idx on beerclub.movimientos (cliente_id, creado_en desc);

create table if not exists beerclub.recompensas (
  id            int generated always as identity primary key,
  nombre        text not null,
  costo_puntos  integer not null check (costo_puntos > 0),
  activa        boolean not null default true,
  orden         int not null default 0
);

create table if not exists beerclub.canjes (
  id             bigint generated always as identity primary key,
  cliente_id     uuid not null references beerclub.clientes(id),
  recompensa_id  int not null references beerclub.recompensas(id),
  codigo         text not null,
  expira_en      timestamptz not null,
  usado_en       timestamptz,
  staff_id       uuid references beerclub.staff(auth_id),
  creado_en      timestamptz not null default now()
);
create index if not exists canjes_codigo_idx on beerclub.canjes (codigo) where usado_en is null;

-- ─── Vista de saldo y nivel ───────────────────────────────
create or replace view beerclub.saldos with (security_invoker = true) as
select c.id as cliente_id,
       coalesce(sum(m.puntos),0)::int as puntos,
       coalesce(sum(m.puntos) filter (where m.tipo in ('compra','bono')),0)::int as acumulado,
       case
         when coalesce(sum(m.puntos) filter (where m.tipo in ('compra','bono')),0) >= 1500 then 'barril'
         when coalesce(sum(m.puntos) filter (where m.tipo in ('compra','bono')),0) >= 500  then 'lupulo'
         else 'espuma'
       end as nivel,
       max(m.creado_en) filter (where m.tipo = 'compra') as ultima_visita
from beerclub.clientes c
left join beerclub.movimientos m on m.cliente_id = c.id
group by c.id;

-- ─── Seguridad (RLS) ──────────────────────────────────────
alter table beerclub.clientes    enable row level security;
alter table beerclub.staff       enable row level security;
alter table beerclub.movimientos enable row level security;
alter table beerclub.recompensas enable row level security;
alter table beerclub.canjes      enable row level security;

create or replace function beerclub.es_staff(p_rol text default null)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from beerclub.staff s
                 where s.auth_id = auth.uid() and s.activo
                   and (p_rol is null or s.rol = p_rol or s.rol = 'admin'));
$$;

-- Los clientes no leen tablas: solo usan funciones con su token. El personal sí lee.
drop policy if exists "staff ve clientes" on beerclub.clientes;
create policy "staff ve clientes" on beerclub.clientes for select to authenticated
  using (beerclub.es_staff());

drop policy if exists "staff ve movimientos" on beerclub.movimientos;
create policy "staff ve movimientos" on beerclub.movimientos for select to authenticated
  using (beerclub.es_staff());

drop policy if exists "recompensas visibles" on beerclub.recompensas;
create policy "recompensas visibles" on beerclub.recompensas for select to anon, authenticated
  using (activa or beerclub.es_staff('admin'));

drop policy if exists "staff ve canjes" on beerclub.canjes;
create policy "staff ve canjes" on beerclub.canjes for select to authenticated
  using (beerclub.es_staff());

drop policy if exists "staff se ve" on beerclub.staff;
create policy "staff se ve" on beerclub.staff for select to authenticated
  using (auth_id = auth.uid() or beerclub.es_staff('admin'));
-- Sin políticas de insert/update/delete: toda escritura pasa por las funciones de abajo.

-- ─── Funciones (API) ──────────────────────────────────────

-- Cliente: registro con celular + PIN. Devuelve el token de su tarjeta (se guarda en el navegador
-- y va en el enlace que se manda por WhatsApp: https://tu-sitio/club.html#t=<token>)
create or replace function beerclub.registrar_cliente(p_nombre text, p_telefono text, p_pin text,
                                                      p_fecha_nac date default null,
                                                      p_acepta_whatsapp boolean default true,
                                                      p_codigo_referido text default null)
returns text language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_tel text; v_ref uuid; v_token text;
begin
  v_tel := regexp_replace(p_telefono, '\D', '', 'g');
  if length(v_tel) < 10 then raise exception 'Número de celular inválido'; end if;
  if p_pin !~ '^\d{4}$' then raise exception 'El PIN debe tener 4 dígitos'; end if;
  if length(trim(p_nombre)) < 2 then raise exception 'Escribe tu nombre'; end if;
  if exists (select 1 from beerclub.clientes where telefono = v_tel) then
    raise exception 'Este celular ya está registrado. Entra con tu PIN';
  end if;

  if p_codigo_referido is not null then
    select id into v_ref from beerclub.clientes where left(qr_token,6) = lower(p_codigo_referido);
  end if;

  insert into beerclub.clientes (telefono, pin_hash, nombre, fecha_nac, acepta_whatsapp, referido_por)
  values (v_tel, extensions.crypt(p_pin, extensions.gen_salt('bf')), trim(p_nombre), p_fecha_nac, p_acepta_whatsapp, v_ref)
  returning id, qr_token into v_id, v_token;

  insert into beerclub.movimientos (cliente_id, tipo, puntos, nota) values (v_id, 'bono', 50, 'Bienvenida');
  if v_ref is not null then
    insert into beerclub.movimientos (cliente_id, tipo, puntos, nota) values (v_ref, 'bono', 100, 'Amigo referido');
  end if;
  return v_token;
end $$;

-- Cliente: entrar en otro teléfono / recuperar tarjeta. 5 intentos fallidos = bloqueo de 15 min
create or replace function beerclub.entrar(p_telefono text, p_pin text)
returns text language plpgsql security definer set search_path = '' as $$
declare c beerclub.clientes;
begin
  select * into c from beerclub.clientes where telefono = regexp_replace(p_telefono, '\D', '', 'g');
  if c.id is null then raise exception 'Celular o PIN incorrecto'; end if;
  if c.bloqueado_hasta > now() then raise exception 'Demasiados intentos. Prueba en 15 minutos'; end if;
  if c.pin_hash <> extensions.crypt(p_pin, c.pin_hash) then
    update beerclub.clientes set
      bloqueado_hasta = case when intentos + 1 >= 5 then now() + interval '15 minutes' end,
      intentos = case when intentos + 1 >= 5 then 0 else intentos + 1 end
    where id = c.id;
    raise exception 'Celular o PIN incorrecto';
  end if;
  update beerclub.clientes set intentos = 0, bloqueado_hasta = null where id = c.id;
  return c.qr_token;
end $$;

-- Cliente: todo lo que necesita la tarjeta en una sola llamada (la web la consulta cada pocos segundos
-- mientras está abierta, así aparece el aviso "+35 pts" sin Realtime)
create or replace function beerclub.mi_tarjeta(p_token text)
returns json language sql stable security definer set search_path = '' as $$
  select json_build_object(
    'nombre', c.nombre, 'qr', c.qr_token, 'codigo_amigo', upper(left(c.qr_token,6)),
    'puntos', s.puntos, 'acumulado', s.acumulado, 'nivel', s.nivel,
    'historial', coalesce((select json_agg(h) from (
        select tipo, puntos, nota, creado_en from beerclub.movimientos
        where cliente_id = c.id order by creado_en desc limit 20) h), '[]'::json))
  from beerclub.clientes c join beerclub.saldos s on s.cliente_id = c.id
  where c.qr_token = p_token;
$$;

-- Staff: escanea QR + monto → suma puntos (con multiplicador por nivel)
create or replace function beerclub.sumar_puntos(p_qr text, p_monto numeric, p_ticket text default null)
returns json language plpgsql security definer set search_path = '' as $$
declare v_cli uuid; v_nivel text; v_mult numeric; v_pts int; v_saldo int;
begin
  if not beerclub.es_staff('mesero') then raise exception 'Solo personal autorizado'; end if;
  if p_monto <= 0 or p_monto > 1000 then raise exception 'Monto fuera de rango'; end if;

  select id into v_cli from beerclub.clientes where qr_token = p_qr;
  if v_cli is null then raise exception 'QR no válido'; end if;

  if exists (select 1 from beerclub.movimientos where cliente_id = v_cli and tipo = 'compra'
             and creado_en > now() - interval '10 minutes') then
    raise exception 'Este cliente ya sumó puntos hace menos de 10 minutos';
  end if;

  select nivel into v_nivel from beerclub.saldos where cliente_id = v_cli;
  v_mult := case v_nivel when 'barril' then 1.5 when 'lupulo' then 1.25 else 1 end;
  v_pts  := floor(p_monto * 10 * v_mult);

  insert into beerclub.movimientos (cliente_id, staff_id, tipo, monto_compra, puntos, ref_ticket)
  values (v_cli, auth.uid(), 'compra', p_monto, v_pts, p_ticket);

  select puntos, nivel into v_saldo, v_nivel from beerclub.saldos where cliente_id = v_cli;
  return json_build_object('puntos_sumados', v_pts, 'saldo', v_saldo, 'nivel', v_nivel,
                           'cliente', (select nombre from beerclub.clientes where id = v_cli));
end $$;

-- Cliente: pide un canje → código de 6 dígitos válido 5 minutos
create or replace function beerclub.solicitar_canje(p_token text, p_recompensa int)
returns json language plpgsql security definer set search_path = '' as $$
declare v_cli uuid; v_costo int; v_saldo int; v_cod text; v_exp timestamptz;
begin
  select id into v_cli from beerclub.clientes where qr_token = p_token;
  if v_cli is null then raise exception 'No registrado'; end if;
  select costo_puntos into v_costo from beerclub.recompensas where id = p_recompensa and activa;
  if v_costo is null then raise exception 'Recompensa no disponible'; end if;
  select puntos into v_saldo from beerclub.saldos where cliente_id = v_cli;
  if v_saldo < v_costo then raise exception 'Puntos insuficientes'; end if;

  update beerclub.canjes set expira_en = now() where cliente_id = v_cli and usado_en is null and expira_en > now();
  v_cod := lpad((floor(random()*1000000))::int::text, 6, '0');
  v_exp := now() + interval '5 minutes';
  insert into beerclub.canjes (cliente_id, recompensa_id, codigo, expira_en) values (v_cli, p_recompensa, v_cod, v_exp);
  return json_build_object('codigo', v_cod, 'expira_en', v_exp);
end $$;

-- Staff: confirma el canje → descuenta puntos
create or replace function beerclub.confirmar_canje(p_codigo text)
returns json language plpgsql security definer set search_path = '' as $$
declare v beerclub.canjes; v_costo int; v_nombre text;
begin
  if not beerclub.es_staff('mesero') then raise exception 'Solo personal autorizado'; end if;
  select * into v from beerclub.canjes where codigo = p_codigo and usado_en is null and expira_en > now()
    order by creado_en desc limit 1 for update;
  if v.id is null then raise exception 'Código inválido o vencido'; end if;
  select costo_puntos, nombre into v_costo, v_nombre from beerclub.recompensas where id = v.recompensa_id;
  if (select puntos from beerclub.saldos where cliente_id = v.cliente_id) < v_costo then
    raise exception 'Puntos insuficientes';
  end if;
  update beerclub.canjes set usado_en = now(), staff_id = auth.uid() where id = v.id;
  insert into beerclub.movimientos (cliente_id, staff_id, tipo, puntos, nota)
  values (v.cliente_id, auth.uid(), 'canje', -v_costo, v_nombre);
  return json_build_object('recompensa', v_nombre,
                           'cliente', (select nombre from beerclub.clientes where id = v.cliente_id));
end $$;

-- Admin: ajuste manual (corregir errores; queda registrado)
create or replace function beerclub.ajustar_puntos(p_cliente uuid, p_puntos int, p_nota text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not beerclub.es_staff('admin') then raise exception 'Solo admin'; end if;
  insert into beerclub.movimientos (cliente_id, staff_id, tipo, puntos, nota)
  values (p_cliente, auth.uid(), 'ajuste', p_puntos, p_nota);
end $$;

-- Admin: métricas del panel
create or replace function beerclub.panel_resumen()
returns json language plpgsql stable security definer set search_path = '' as $$
begin
  if not beerclub.es_staff('admin') then raise exception 'Solo admin'; end if;
  return json_build_object(
    'socios',        (select count(*) from beerclub.clientes),
    'activos_30d',   (select count(*) from beerclub.saldos where ultima_visita > now() - interval '30 days'),
    'visitas_mes',   (select count(*) from beerclub.movimientos where tipo='compra' and creado_en > date_trunc('month', now())),
    'ticket_prom',   (select round(avg(monto_compra),2) from beerclub.movimientos where tipo='compra' and creado_en > now() - interval '30 days'),
    'canjes_mes',    (select count(*) from beerclub.canjes where usado_en > date_trunc('month', now())),
    'dormidos',      coalesce((select json_agg(d) from (
                        select c.nombre, c.telefono, s.ultima_visita, s.puntos,
                               'https://wa.me/' || c.telefono || '?text=' ||
                               replace('Hola ' || c.nombre || ', te extrañamos en Ficoa Beer Garden. Tienes ' || s.puntos || ' pts esperándote 🍺', ' ', '%20') as whatsapp
                        from beerclub.clientes c join beerclub.saldos s on s.cliente_id = c.id
                        where c.acepta_whatsapp and s.ultima_visita < now() - interval '30 days'
                        order by s.ultima_visita limit 50) d), '[]'::json)
  );
end $$;

-- ─── Permisos ─────────────────────────────────────────────
grant usage on schema beerclub to anon, authenticated;
grant select on all tables in schema beerclub to authenticated;
grant select on beerclub.recompensas to anon;
revoke execute on all functions in schema beerclub from public, anon;
grant execute on all functions in schema beerclub to authenticated;
-- Lo único que puede usar un cliente sin cuenta:
grant execute on function beerclub.es_staff(text),
                          beerclub.registrar_cliente(text,text,text,date,boolean,text),
                          beerclub.entrar(text,text),
                          beerclub.mi_tarjeta(text),
                          beerclub.solicitar_canje(text,int) to anon;

-- ─── Datos iniciales ──────────────────────────────────────
insert into beerclub.recompensas (nombre, costo_puntos, orden)
select * from (values ('Jarra de barril', 150, 1), ('10 alitas', 250, 2), ('Picada para 2', 600, 3)) v(n,c,o)
where not exists (select 1 from beerclub.recompensas);

-- Para dar de alta un mesero/admin: créalo en Authentication → Users → Add user (email + clave) y luego:
-- insert into beerclub.staff (auth_id, nombre, rol) values ('<uuid del usuario>', 'Carlos', 'admin');
