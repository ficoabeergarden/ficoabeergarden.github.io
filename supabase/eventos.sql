-- Eventos y entradas · Ficoa Beer Garden
-- Ejecutar DESPUÉS de beerclub.sql, completo, en Supabase → SQL Editor. No borra ni cambia nada existente.
-- Flujo: el cliente reserva (entradas "pendiente") → transfiere → cualquier staff confirma el pago
-- → cada entrada pasa a "valida" con su propio QR → en la puerta se escanea y queda "usada".

-- ─── Tablas ───────────────────────────────────────────────
create table if not exists beerclub.eventos (
  id          int generated always as identity primary key,
  slug        text unique not null,
  nombre      text not null,
  fecha       timestamptz not null,
  descripcion text,
  datos_pago  text not null,                 -- banco, tipo y n.º de cuenta, titular, cédula
  activo      boolean not null default true,
  creado_en   timestamptz not null default now()
);

create table if not exists beerclub.tipos_entrada (
  id        int generated always as identity primary key,
  evento_id int not null references beerclub.eventos(id) on delete cascade,
  nombre    text not null,
  precio    numeric(10,2) not null check (precio >= 0),
  cupo      int check (cupo > 0),            -- null = sin límite
  orden     int not null default 0
);

create table if not exists beerclub.pedidos (
  id         bigint generated always as identity primary key,
  evento_id  int not null references beerclub.eventos(id),
  cliente_id uuid references beerclub.clientes(id),   -- si es socio del Beer Club
  nombre     text not null,
  telefono   text not null,
  ref        text unique not null,                    -- 6 letras que el cliente pone en la transferencia
  token      text unique not null default replace(gen_random_uuid()::text,'-',''),
  total      numeric(10,2) not null default 0,
  estado     text not null default 'pendiente' check (estado in ('pendiente','pagado','anulado')),
  staff_id   uuid references beerclub.staff(auth_id),
  pagado_en  timestamptz,
  creado_en  timestamptz not null default now()
);
create index if not exists pedidos_evento_idx on beerclub.pedidos (evento_id, estado);
create index if not exists pedidos_tel_idx on beerclub.pedidos (telefono);

create table if not exists beerclub.entradas (
  id        bigint generated always as identity primary key,
  pedido_id bigint not null references beerclub.pedidos(id) on delete cascade,
  tipo_id   int not null references beerclub.tipos_entrada(id),
  n         int not null,                                -- 1 de 4, 2 de 4…
  codigo    text unique not null default replace(gen_random_uuid()::text,'-',''),
  estado    text not null default 'pendiente' check (estado in ('pendiente','valida','usada','anulada')),
  usado_en  timestamptz,
  usado_por uuid references beerclub.staff(auth_id)
);
create index if not exists entradas_pedido_idx on beerclub.entradas (pedido_id);

-- ─── Seguridad ────────────────────────────────────────────
alter table beerclub.eventos       enable row level security;
alter table beerclub.tipos_entrada enable row level security;
alter table beerclub.pedidos       enable row level security;
alter table beerclub.entradas      enable row level security;

drop policy if exists "staff ve eventos" on beerclub.eventos;
create policy "staff ve eventos" on beerclub.eventos for select to authenticated using (beerclub.es_staff());
drop policy if exists "staff ve tipos" on beerclub.tipos_entrada;
create policy "staff ve tipos" on beerclub.tipos_entrada for select to authenticated using (beerclub.es_staff());
drop policy if exists "staff ve pedidos" on beerclub.pedidos;
create policy "staff ve pedidos" on beerclub.pedidos for select to authenticated using (beerclub.es_staff());
drop policy if exists "staff ve entradas" on beerclub.entradas;
create policy "staff ve entradas" on beerclub.entradas for select to authenticated using (beerclub.es_staff());
-- Los clientes no leen tablas: todo pasa por las funciones de abajo.

-- ─── Funciones internas ───────────────────────────────────
create or replace function beerclub._pedido_json(p_id bigint)
returns json language sql stable security definer set search_path = '' as $$
  select json_build_object(
    'token', p.token, 'ref', p.ref, 'estado', p.estado, 'nombre', p.nombre, 'total', p.total, 'creado_en', p.creado_en,
    'evento', json_build_object('nombre', e.nombre, 'fecha', e.fecha, 'slug', e.slug, 'datos_pago', e.datos_pago),
    'entradas', coalesce((select json_agg(json_build_object(
          'n', x.n, 'tipo', t.nombre, 'estado', x.estado, 'usado_en', x.usado_en,
          'codigo', case when x.estado in ('valida','usada') then x.codigo end) order by x.n)
        from beerclub.entradas x join beerclub.tipos_entrada t on t.id = x.tipo_id
        where x.pedido_id = p.id and x.estado <> 'anulada'), '[]'::json))
  from beerclub.pedidos p join beerclub.eventos e on e.id = p.evento_id
  where p.id = p_id;
$$;

-- ─── Cliente (sin cuenta) ─────────────────────────────────

-- Agenda pública: eventos activos con sus tipos de entrada y cupos disponibles
create or replace function beerclub.eventos_publicos()
returns json language sql stable security definer set search_path = '' as $$
  select coalesce(json_agg(e order by e.fecha), '[]'::json) from (
    select ev.id, ev.slug, ev.nombre, ev.fecha, ev.descripcion,
      (select coalesce(json_agg(json_build_object('id', t.id, 'nombre', t.nombre, 'precio', t.precio,
          'disponibles', case when t.cupo is null then null else greatest(0, t.cupo -
            (select count(*) from beerclub.entradas x where x.tipo_id = t.id and x.estado <> 'anulada')) end)
          order by t.orden, t.precio), '[]'::json)
       from beerclub.tipos_entrada t where t.evento_id = ev.id) as tipos
    from beerclub.eventos ev
    where ev.activo and ev.fecha > now() - interval '12 hours') e;
$$;

-- Reserva: crea el pedido y sus entradas en "pendiente". Devuelve el token para ver el pedido.
-- p_items: [{"tipo": 3, "cantidad": 2}, …]. Si viene p_token_club, se usa el nombre/celular del socio.
create or replace function beerclub.comprar_entradas(p_evento int, p_nombre text, p_telefono text,
                                                     p_items json, p_token_club text default null)
returns text language plpgsql security definer set search_path = '' as $$
declare v_cli uuid; v_tel text; v_nom text; v_ped bigint; v_tok text; v_ref text;
        v_total numeric := 0; v_cant int := 0; v_n int := 0; v_q int; v_usadas int;
        it json; t beerclub.tipos_entrada;
begin
  if not exists (select 1 from beerclub.eventos where id = p_evento and activo and fecha > now() - interval '12 hours') then
    raise exception 'Este evento ya no está a la venta';
  end if;
  if p_token_club is not null then
    select id, telefono, nombre into v_cli, v_tel, v_nom from beerclub.clientes where qr_token = p_token_club;
  end if;
  if v_cli is null then
    v_tel := regexp_replace(coalesce(p_telefono, ''), '\D', '', 'g');
    v_nom := trim(coalesce(p_nombre, ''));
    if length(v_tel) < 10 then raise exception 'Número de celular inválido'; end if;
    if length(v_nom) < 2 then raise exception 'Escribe tu nombre'; end if;
    select id into v_cli from beerclub.clientes where telefono = v_tel;   -- socio que no entró con su tarjeta
  end if;
  if (select count(*) from beerclub.pedidos where telefono = v_tel and evento_id = p_evento and estado = 'pendiente') >= 3 then
    raise exception 'Ya tienes pedidos pendientes de pago. Envía tu comprobante o escríbenos';
  end if;

  loop
    v_ref := upper(substr(md5(random()::text), 1, 6));
    exit when not exists (select 1 from beerclub.pedidos where ref = v_ref);
  end loop;
  insert into beerclub.pedidos (evento_id, cliente_id, nombre, telefono, ref)
  values (p_evento, v_cli, v_nom, v_tel, v_ref) returning id, token into v_ped, v_tok;

  for it in select * from json_array_elements(p_items) loop
    v_q := (it->>'cantidad')::int;
    continue when v_q is null or v_q <= 0;
    select * into t from beerclub.tipos_entrada where id = (it->>'tipo')::int and evento_id = p_evento for update;
    if t.id is null then raise exception 'Tipo de entrada no válido'; end if;
    if t.cupo is not null then
      select count(*) into v_usadas from beerclub.entradas where tipo_id = t.id and estado <> 'anulada';
      if v_usadas + v_q > t.cupo then
        raise exception 'Solo quedan % entradas %', greatest(0, t.cupo - v_usadas), t.nombre;
      end if;
    end if;
    for i in 1..v_q loop
      v_n := v_n + 1;
      insert into beerclub.entradas (pedido_id, tipo_id, n) values (v_ped, t.id, v_n);
    end loop;
    v_total := v_total + t.precio * v_q;
    v_cant := v_cant + v_q;
  end loop;
  if v_cant = 0 then raise exception 'Elige al menos una entrada'; end if;
  if v_cant > 10 then raise exception 'Máximo 10 entradas por pedido'; end if;
  update beerclub.pedidos set total = v_total where id = v_ped;
  return v_tok;
end $$;

-- Ver un pedido (los códigos QR solo aparecen cuando el pago está confirmado)
create or replace function beerclub.mi_pedido(p_token text)
returns json language sql stable security definer set search_path = '' as $$
  select beerclub._pedido_json(id) from beerclub.pedidos where token = p_token;
$$;

-- Socio del Beer Club: todas sus entradas de eventos próximos (aunque las haya comprado en otro teléfono)
create or replace function beerclub.mis_entradas(p_token_club text)
returns json language sql stable security definer set search_path = '' as $$
  select coalesce(json_agg(beerclub._pedido_json(p.id) order by e.fecha, p.creado_en), '[]'::json)
  from beerclub.clientes c
  join beerclub.pedidos p on (p.cliente_id = c.id or p.telefono = c.telefono) and p.estado <> 'anulado'
  join beerclub.eventos e on e.id = p.evento_id and e.fecha > now() - interval '12 hours'
  where c.qr_token = p_token_club;
$$;

-- Una sola entrada (la que se reenvía a un amigo)
create or replace function beerclub.ver_entrada(p_codigo text)
returns json language sql stable security definer set search_path = '' as $$
  select json_build_object('n', x.n, 'tipo', t.nombre, 'estado', x.estado, 'usado_en', x.usado_en, 'codigo', x.codigo,
    'de', (select count(*) from beerclub.entradas y where y.pedido_id = p.id and y.estado <> 'anulada'),
    'nombre', p.nombre, 'evento', json_build_object('nombre', e.nombre, 'fecha', e.fecha, 'slug', e.slug))
  from beerclub.entradas x
  join beerclub.tipos_entrada t on t.id = x.tipo_id
  join beerclub.pedidos p on p.id = x.pedido_id
  join beerclub.eventos e on e.id = p.evento_id
  where x.codigo = p_codigo and x.estado in ('valida','usada');
$$;

-- ─── Personal (cualquier staff) ───────────────────────────
create or replace function beerclub.eventos_staff()
returns json language plpgsql stable security definer set search_path = '' as $$
begin
  if not beerclub.es_staff() then raise exception 'Solo personal autorizado'; end if;
  return coalesce((select json_agg(e order by e.fecha) from (
    select ev.id, ev.slug, ev.nombre, ev.fecha, ev.activo,
      (select count(*) from beerclub.pedidos p where p.evento_id = ev.id and p.estado = 'pendiente') as pendientes,
      (select count(*) from beerclub.entradas x join beerclub.pedidos p on p.id = x.pedido_id
        where p.evento_id = ev.id and x.estado in ('valida','usada')) as vendidas,
      (select count(*) from beerclub.entradas x join beerclub.pedidos p on p.id = x.pedido_id
        where p.evento_id = ev.id and x.estado = 'usada') as adentro
    from beerclub.eventos ev
    where ev.activo or ev.fecha > now() - interval '2 days') e), '[]'::json);
end $$;

create or replace function beerclub.pedidos_evento(p_evento int)
returns json language plpgsql stable security definer set search_path = '' as $$
begin
  if not beerclub.es_staff() then raise exception 'Solo personal autorizado'; end if;
  return coalesce((select json_agg(json_build_object(
      'id', p.id, 'ref', p.ref, 'nombre', p.nombre, 'telefono', p.telefono, 'total', p.total, 'estado', p.estado,
      'token', p.token, 'socio', p.cliente_id is not null, 'creado_en', p.creado_en, 'pagado_en', p.pagado_en,
      'entradas', (select json_agg(json_build_object('id', x.id, 'n', x.n, 'tipo', t.nombre, 'estado', x.estado, 'usado_en', x.usado_en) order by x.n)
                   from beerclub.entradas x join beerclub.tipos_entrada t on t.id = x.tipo_id where x.pedido_id = p.id))
    order by p.creado_en desc)
    from beerclub.pedidos p where p.evento_id = p_evento and p.estado <> 'anulado'), '[]'::json);
end $$;

-- Confirmar transferencia: activa los QR y, si es socio, suma 10 pts por cada $1
create or replace function beerclub.confirmar_pago(p_pedido bigint)
returns json language plpgsql security definer set search_path = '' as $$
declare p beerclub.pedidos; v_ev text; v_pts int := 0;
begin
  if not beerclub.es_staff() then raise exception 'Solo personal autorizado'; end if;
  select * into p from beerclub.pedidos where id = p_pedido for update;
  if p.id is null then raise exception 'Pedido no encontrado'; end if;
  if p.estado = 'pagado' then raise exception 'Este pedido ya estaba confirmado'; end if;
  if p.estado = 'anulado' then raise exception 'Este pedido fue anulado'; end if;
  update beerclub.pedidos set estado = 'pagado', pagado_en = now(), staff_id = auth.uid() where id = p.id;
  update beerclub.entradas set estado = 'valida' where pedido_id = p.id and estado = 'pendiente';
  select nombre into v_ev from beerclub.eventos where id = p.evento_id;
  if p.cliente_id is not null and p.total > 0 then
    v_pts := floor(p.total * 10);
    insert into beerclub.movimientos (cliente_id, staff_id, tipo, puntos, nota)
    values (p.cliente_id, auth.uid(), 'bono', v_pts, 'Entradas · ' || v_ev);
  end if;
  return json_build_object('nombre', p.nombre, 'telefono', p.telefono, 'token', p.token, 'evento', v_ev, 'puntos', v_pts,
                           'cantidad', (select count(*) from beerclub.entradas where pedido_id = p.id));
end $$;

-- Anular: un pedido pendiente lo anula cualquier staff; uno ya pagado, solo admin
create or replace function beerclub.anular_pedido(p_pedido bigint)
returns void language plpgsql security definer set search_path = '' as $$
declare v_estado text;
begin
  if not beerclub.es_staff() then raise exception 'Solo personal autorizado'; end if;
  select estado into v_estado from beerclub.pedidos where id = p_pedido for update;
  if v_estado is null then raise exception 'Pedido no encontrado'; end if;
  if v_estado = 'pagado' and not beerclub.es_staff('admin') then raise exception 'Un pedido pagado solo lo anula un admin'; end if;
  update beerclub.pedidos set estado = 'anulado' where id = p_pedido;
  update beerclub.entradas set estado = 'anulada' where pedido_id = p_pedido and estado in ('pendiente','valida');
end $$;

-- Reemitir: nuevo QR para una entrada; el anterior deja de servir al instante
create or replace function beerclub.reemitir_entrada(p_entrada bigint)
returns json language plpgsql security definer set search_path = '' as $$
declare v_ped bigint;
begin
  if not beerclub.es_staff() then raise exception 'Solo personal autorizado'; end if;
  update beerclub.entradas set codigo = replace(gen_random_uuid()::text,'-','')
  where id = p_entrada and estado = 'valida' returning pedido_id into v_ped;
  if v_ped is null then raise exception 'Solo se puede reemitir una entrada válida sin usar'; end if;
  return (select json_build_object('nombre', nombre, 'telefono', telefono, 'token', token) from beerclub.pedidos where id = v_ped);
end $$;

-- Lista para la puerta (se guarda en el teléfono y permite validar sin internet)
create or replace function beerclub.lista_puerta(p_evento int)
returns json language plpgsql stable security definer set search_path = '' as $$
begin
  if not beerclub.es_staff() then raise exception 'Solo personal autorizado'; end if;
  return coalesce((select json_agg(json_build_object('c', x.codigo, 'nombre', p.nombre, 'tipo', t.nombre, 'n', x.n,
      'de', (select count(*) from beerclub.entradas y where y.pedido_id = p.id and y.estado <> 'anulada'),
      'estado', x.estado, 'usado_en', x.usado_en))
    from beerclub.entradas x
    join beerclub.pedidos p on p.id = x.pedido_id
    join beerclub.tipos_entrada t on t.id = x.tipo_id
    where p.evento_id = p_evento and x.estado in ('valida','usada')), '[]'::json);
end $$;

-- Validar en la puerta. Marca "usada" en un solo paso (no se puede usar dos veces).
-- p_cuando: hora real del escaneo cuando se sincroniza algo validado sin internet.
create or replace function beerclub.validar_entrada(p_codigo text, p_evento int, p_cuando timestamptz default null)
returns json language plpgsql security definer set search_path = '' as $$
declare x record;
begin
  if not beerclub.es_staff() then raise exception 'Solo personal autorizado'; end if;
  select en.id, en.estado, en.usado_en, en.n, t.nombre as tipo, p.nombre, p.evento_id, ev.nombre as evento,
         (select count(*) from beerclub.entradas y where y.pedido_id = p.id and y.estado <> 'anulada') as de
    into x
  from beerclub.entradas en
  join beerclub.tipos_entrada t on t.id = en.tipo_id
  join beerclub.pedidos p on p.id = en.pedido_id
  join beerclub.eventos ev on ev.id = p.evento_id
  where en.codigo = p_codigo
  for update of en;
  if not found then return json_build_object('ok', false, 'motivo', 'no_existe'); end if;
  if x.evento_id <> p_evento then return json_build_object('ok', false, 'motivo', 'otro_evento', 'evento', x.evento); end if;
  if x.estado = 'usada' then
    return json_build_object('ok', false, 'motivo', 'usada', 'usado_en', x.usado_en, 'nombre', x.nombre, 'tipo', x.tipo, 'n', x.n, 'de', x.de);
  end if;
  if x.estado <> 'valida' then return json_build_object('ok', false, 'motivo', x.estado, 'nombre', x.nombre); end if;
  update beerclub.entradas set estado = 'usada', usado_en = coalesce(p_cuando, now()), usado_por = auth.uid() where id = x.id;
  return json_build_object('ok', true, 'nombre', x.nombre, 'tipo', x.tipo, 'n', x.n, 'de', x.de);
end $$;

-- ─── Admin ────────────────────────────────────────────────
-- p_tipos: [{"nombre": "General", "precio": 10, "cupo": 150}, {"nombre": "VIP", "precio": 25, "cupo": 30}]
create or replace function beerclub.crear_evento(p_nombre text, p_fecha timestamptz, p_descripcion text,
                                                 p_datos_pago text, p_tipos json)
returns text language plpgsql security definer set search_path = '' as $$
declare v_id int; v_slug text; it json; v_o int := 0;
begin
  if not beerclub.es_staff('admin') then raise exception 'Solo admin'; end if;
  if length(trim(coalesce(p_nombre, ''))) < 3 then raise exception 'Escribe el nombre del evento'; end if;
  if length(trim(coalesce(p_datos_pago, ''))) < 10 then raise exception 'Faltan los datos de la cuenta para transferir'; end if;
  if json_array_length(coalesce(p_tipos, '[]'::json)) = 0 then raise exception 'Agrega al menos un tipo de entrada'; end if;
  v_slug := trim(both '-' from regexp_replace(lower(translate(p_nombre, 'ÁÉÍÓÚÜÑáéíóúüñ', 'AEIOUUNaeiouun')), '[^a-z0-9]+', '-', 'g'));
  v_slug := left(v_slug, 40) || '-' || to_char(p_fecha at time zone 'America/Guayaquil', 'DDMM');
  if exists (select 1 from beerclub.eventos where slug = v_slug) then v_slug := v_slug || '-' || substr(md5(random()::text), 1, 3); end if;
  insert into beerclub.eventos (slug, nombre, fecha, descripcion, datos_pago)
  values (v_slug, trim(p_nombre), p_fecha, nullif(trim(coalesce(p_descripcion, '')), ''), trim(p_datos_pago)) returning id into v_id;
  for it in select * from json_array_elements(p_tipos) loop
    v_o := v_o + 1;
    insert into beerclub.tipos_entrada (evento_id, nombre, precio, cupo, orden)
    values (v_id, trim(it->>'nombre'), (it->>'precio')::numeric, nullif(it->>'cupo', '')::int, v_o);
  end loop;
  return v_slug;
end $$;

create or replace function beerclub.activar_evento(p_evento int, p_activo boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not beerclub.es_staff('admin') then raise exception 'Solo admin'; end if;
  update beerclub.eventos set activo = p_activo where id = p_evento;
end $$;

-- ─── Permisos ─────────────────────────────────────────────
grant select on all tables in schema beerclub to authenticated;
revoke execute on all functions in schema beerclub from public, anon;
grant execute on all functions in schema beerclub to authenticated;
revoke execute on function beerclub._pedido_json(bigint) from authenticated;
grant execute on function beerclub.es_staff(text),
                          beerclub.registrar_cliente(text,text,text,date,boolean,text),
                          beerclub.entrar(text,text),
                          beerclub.mi_tarjeta(text),
                          beerclub.solicitar_canje(text,int),
                          beerclub.eventos_publicos(),
                          beerclub.comprar_entradas(int,text,text,json,text),
                          beerclub.mi_pedido(text),
                          beerclub.mis_entradas(text),
                          beerclub.ver_entrada(text) to anon;
