-- =====================================================================
-- Barbearia App — banco de dados (Supabase / Postgres)
-- Cole este arquivo inteiro no SQL Editor do Supabase e clique em RUN.
-- Pode rodar de novo sem problema: ele não apaga dados existentes.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------- Tabelas ----------

-- Cada barbearia que assina o app.
create table if not exists public.barbearias (
  id         uuid primary key default gen_random_uuid(),
  slug       text unique not null check (slug ~ '^[a-z0-9][a-z0-9-]{2,59}$'),
  nome       text not null,
  config     jsonb not null default '{}'::jsonb,  -- cor, horários, serviços, barbeiros, meta
  ativa      boolean not null default true,       -- você desliga aqui quem parar de pagar
  criado_em  timestamptz not null default now()
);

-- Assinatura: novas barbearias ganham 10 dias de teste grátis.
alter table public.barbearias add column if not exists vencimento date;
alter table public.barbearias alter column vencimento set default ((now() at time zone 'America/Sao_Paulo')::date + 10);
alter table public.barbearias add column if not exists mensalidade numeric(10,2);
alter table public.barbearias add column if not exists obs_admin text;

-- Você (e quem mais você colocar aqui) administra o sistema inteiro.
create table if not exists public.admins (
  user_id   uuid primary key references auth.users(id) on delete cascade,
  criado_em timestamptz not null default now()
);

-- Histórico de mensalidades recebidas.
create table if not exists public.pagamentos (
  id           uuid primary key default gen_random_uuid(),
  barbearia_id uuid not null references public.barbearias(id) on delete cascade,
  valor        numeric(10,2) not null,
  meses        integer not null default 1,
  pago_em      timestamptz not null default now(),
  vence_ate    date,
  obs          text
);

-- Quem tem login em cada barbearia (dono ou barbeiro).
create table if not exists public.membros (
  barbearia_id uuid not null references public.barbearias(id) on delete cascade,
  user_id      uuid not null references auth.users(id) on delete cascade,
  papel        text not null default 'barbeiro' check (papel in ('dono', 'barbeiro')),
  criado_em    timestamptz not null default now(),
  primary key (barbearia_id, user_id)
);

-- E-mails convidados pelo dono. Viram membros no primeiro login.
create table if not exists public.convites (
  barbearia_id uuid not null references public.barbearias(id) on delete cascade,
  email        text not null,
  papel        text not null default 'barbeiro' check (papel in ('dono', 'barbeiro')),
  criado_em    timestamptz not null default now(),
  primary key (barbearia_id, email)
);

-- Todos os registros do dia a dia: agenda, comandas, clientes, estoque, despesas, vales.
create table if not exists public.registros (
  barbearia_id  uuid not null references public.barbearias(id) on delete cascade,
  colecao       text not null check (colecao in ('produtos', 'agendamentos', 'comandas', 'clientes', 'despesas', 'vales')),
  id            text not null,
  dados         jsonb not null default '{}'::jsonb,
  atualizado_em timestamptz not null default now(),
  primary key (barbearia_id, colecao, id)
);
create index if not exists registros_colecao_idx on public.registros (barbearia_id, colecao);

-- Qual barbeiro da agenda é cada conta (o barbeiro só vê as próprias comandas e ganhos).
alter table public.membros  add column if not exists barbeiro_id text;
alter table public.convites add column if not exists barbeiro_id text;

create or replace function public.tocar_atualizado_em() returns trigger
language plpgsql as $$
begin
  new.atualizado_em := now();
  return new;
end $$;

drop trigger if exists registros_atualizado_em on public.registros;
create trigger registros_atualizado_em before update on public.registros
  for each row execute function public.tocar_atualizado_em();

-- ---------- Quem pode o quê ----------

-- Dias de tolerância depois do vencimento antes de bloquear o acesso.
create or replace function public.tolerancia_dias() returns integer
language sql immutable as $$ select 5 $$;

-- Liberada = não foi desativada por você E a mensalidade não venceu há mais que a tolerância.
create or replace function public.barbearia_liberada(p_ativa boolean, p_venc date) returns boolean
language sql stable as $$
  select coalesce(p_ativa, false)
     and (p_venc is null or p_venc + public.tolerancia_dias() >= (now() at time zone 'America/Sao_Paulo')::date);
$$;

create or replace function public.eh_membro(b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from membros m join barbearias x on x.id = m.barbearia_id
    where m.barbearia_id = b and m.user_id = auth.uid() and barbearia_liberada(x.ativa, x.vencimento)
  );
$$;

create or replace function public.eh_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from admins where user_id = auth.uid());
$$;

create or replace function public.eh_dono(b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from membros where barbearia_id = b and user_id = auth.uid() and papel = 'dono');
$$;

alter table public.barbearias enable row level security;
alter table public.membros    enable row level security;
alter table public.convites   enable row level security;
alter table public.registros  enable row level security;
alter table public.admins     enable row level security;  -- sem regras: só as funções de admin acessam
alter table public.pagamentos enable row level security;  -- idem

drop policy if exists barbearias_ler on public.barbearias;
create policy barbearias_ler on public.barbearias for select using (public.eh_membro(id));
drop policy if exists barbearias_editar on public.barbearias;
create policy barbearias_editar on public.barbearias for update using (public.eh_dono(id)) with check (public.eh_dono(id));

drop policy if exists membros_ler on public.membros;
create policy membros_ler on public.membros for select using (user_id = auth.uid() or public.eh_membro(barbearia_id));
drop policy if exists membros_remover on public.membros;
create policy membros_remover on public.membros for delete using (public.eh_dono(barbearia_id) and user_id <> auth.uid());

drop policy if exists convites_dono on public.convites;
create policy convites_dono on public.convites for all using (public.eh_dono(barbearia_id)) with check (public.eh_dono(barbearia_id));

-- Papel de quem está logado nesta barbearia (só se a barbearia estiver liberada).
create or replace function public.meu_papel(b uuid) returns text
language sql stable security definer set search_path = public as $$
  select m.papel from membros m join barbearias x on x.id = m.barbearia_id
  where m.barbearia_id = b and m.user_id = auth.uid() and barbearia_liberada(x.ativa, x.vencimento) limit 1;
$$;
create or replace function public.meu_barbeiro(b uuid) returns text
language sql stable security definer set search_path = public as $$
  select m.barbeiro_id from membros m where m.barbearia_id = b and m.user_id = auth.uid() limit 1;
$$;

-- Dono: tudo. Barbeiro: agenda, clientes e estoque; comandas e vales só os dele; despesas não.
drop policy if exists registros_membro on public.registros;
drop policy if exists registros_dono on public.registros;
drop policy if exists registros_barbeiro_ler on public.registros;
drop policy if exists registros_barbeiro_criar on public.registros;
drop policy if exists registros_barbeiro_editar on public.registros;
drop policy if exists registros_barbeiro_apagar on public.registros;
create policy registros_dono on public.registros for all
  using (public.meu_papel(barbearia_id) = 'dono') with check (public.meu_papel(barbearia_id) = 'dono');
create policy registros_barbeiro_ler on public.registros for select using (
  public.meu_papel(barbearia_id) = 'barbeiro' and (
    colecao in ('agendamentos', 'clientes', 'produtos')
    or (colecao in ('comandas', 'vales') and dados ->> 'barbeiroId' = public.meu_barbeiro(barbearia_id))));
create policy registros_barbeiro_criar on public.registros for insert with check (
  public.meu_papel(barbearia_id) = 'barbeiro' and (
    colecao in ('agendamentos', 'clientes')
    or (colecao = 'comandas' and dados ->> 'barbeiroId' = public.meu_barbeiro(barbearia_id))));
create policy registros_barbeiro_editar on public.registros for update using (
  public.meu_papel(barbearia_id) = 'barbeiro' and (
    colecao in ('agendamentos', 'clientes', 'produtos')
    or (colecao = 'comandas' and dados ->> 'barbeiroId' = public.meu_barbeiro(barbearia_id))))
  with check (
  public.meu_papel(barbearia_id) = 'barbeiro' and (
    colecao in ('agendamentos', 'clientes', 'produtos')
    or (colecao = 'comandas' and dados ->> 'barbeiroId' = public.meu_barbeiro(barbearia_id))));
create policy registros_barbeiro_apagar on public.registros for delete using (
  public.meu_papel(barbearia_id) = 'barbeiro' and colecao = 'comandas'
  and dados ->> 'barbeiroId' = public.meu_barbeiro(barbearia_id));

-- Ativação, vencimento, mensalidade e anotações só o administrador muda; o dono não consegue mexer.
create or replace function public.proteger_ativa() returns trigger
language plpgsql as $$
begin
  if current_user in ('authenticated', 'anon') and (
       new.ativa is distinct from old.ativa
    or new.vencimento is distinct from old.vencimento
    or new.mensalidade is distinct from old.mensalidade
    or new.obs_admin is distinct from old.obs_admin
    or new.slug is distinct from old.slug) then
    raise exception 'Só o administrador do sistema pode mudar a assinatura de uma barbearia.';
  end if;
  return new;
end $$;

drop trigger if exists barbearias_proteger_ativa on public.barbearias;
create trigger barbearias_proteger_ativa before update on public.barbearias
  for each row execute function public.proteger_ativa();

-- ---------- Funções do painel (usuário logado) ----------

-- Cria a barbearia e coloca quem criou como dono.
create or replace function public.criar_barbearia(p_nome text, p_slug text, p_config jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if auth.uid() is null then raise exception 'Faça login primeiro.'; end if;
  if coalesce(trim(p_nome), '') = '' then raise exception 'Informe o nome da barbearia.'; end if;
  if p_slug !~ '^[a-z0-9][a-z0-9-]{2,59}$' then raise exception 'O link precisa ter de 3 a 60 letras minúsculas, números ou hífens.'; end if;
  if exists (select 1 from barbearias where slug = p_slug) then raise exception 'Esse link já está em uso. Escolha outro.'; end if;
  insert into barbearias (slug, nome, config) values (p_slug, trim(p_nome), coalesce(p_config, '{}'::jsonb)) returning id into v_id;
  insert into membros (barbearia_id, user_id, papel) values (v_id, auth.uid(), 'dono');
  return v_id;
end $$;

-- Transforma convites pendentes do e-mail logado em acesso.
create or replace function public.entrar_por_convite()
returns integer language plpgsql security definer set search_path = public as $$
declare v_email text := lower(coalesce(auth.jwt() ->> 'email', '')); v_n integer;
begin
  if auth.uid() is null or v_email = '' then return 0; end if;
  insert into membros (barbearia_id, user_id, papel, barbeiro_id)
    select barbearia_id, auth.uid(), papel, barbeiro_id from convites where lower(email) = v_email
    on conflict (barbearia_id, user_id) do nothing;
  get diagnostics v_n = row_count;
  delete from convites where lower(email) = v_email;
  return v_n;
end $$;

-- Dono vê quem tem acesso (e-mail, papel e qual barbeiro da agenda é).
create or replace function public.equipe_acessos(p_b uuid)
returns json language plpgsql stable security definer set search_path = public as $$
declare v json;
begin
  if not eh_dono(p_b) then raise exception 'Só o dono vê os acessos.'; end if;
  select coalesce(json_agg(json_build_object('user_id', m.user_id, 'email', u.email, 'papel', m.papel,
           'barbeiro_id', m.barbeiro_id, 'eu', m.user_id = auth.uid()) order by m.criado_em), '[]'::json)
  into v from membros m join auth.users u on u.id = m.user_id where m.barbearia_id = p_b;
  return v;
end $$;

-- Dono muda o papel de alguém ou liga a conta a um barbeiro da agenda.
create or replace function public.equipe_ajustar(p_b uuid, p_user uuid, p_papel text, p_barbeiro text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not eh_dono(p_b) then raise exception 'Só o dono pode mudar acessos.'; end if;
  if p_papel not in ('dono', 'barbeiro') then raise exception 'Papel inválido.'; end if;
  if p_user = auth.uid() and p_papel <> 'dono' then raise exception 'Você não pode tirar o seu próprio acesso de dono.'; end if;
  update membros set papel = p_papel, barbeiro_id = nullif(p_barbeiro, '') where barbearia_id = p_b and user_id = p_user;
  if not found then raise exception 'Pessoa não encontrada na equipe.'; end if;
end $$;

-- ---------- Regras de horário (valem pro painel e pra página do cliente) ----------
-- config.semana: {"0": null | {"abre":"09:00","fecha":"19:00"}, ... "6": ...}  (0 = domingo; null = fechado)
-- config.almoco: {"ini":"12:00","fim":"13:00"} ou null
-- config.barbeiros[].folgas: [0, 1]  (dias da semana de folga)
-- config.bloqueios: [{"id","data":"2026-11-02","barbeiroId":null|"b1","ini":null|"14:00","fim":null|"16:00","motivo"}]
create or replace function public.expediente(c jsonb, p_dia date) returns jsonb
language sql immutable as $$
  select case when c ? 'semana' then c -> 'semana' -> (extract(dow from p_dia)::int::text)
              else jsonb_build_object('abre', coalesce(c ->> 'abre', '09:00'), 'fecha', coalesce(c ->> 'fecha', '19:00')) end;
$$;

create or replace function public.horario_permitido(c jsonb, p_dia date, p_ini int, p_dur int, p_barb text) returns boolean
language plpgsql immutable as $$
declare e jsonb; b jsonb; x jsonb;
begin
  e := expediente(c, p_dia);
  if e is null or jsonb_typeof(e) <> 'object' then return false; end if;
  if p_ini < minutos(e ->> 'abre') or p_ini + p_dur > minutos(e ->> 'fecha') then return false; end if;
  if jsonb_typeof(c -> 'almoco') = 'object' and coalesce(c -> 'almoco' ->> 'ini', '') <> '' then
    if p_ini < minutos(c -> 'almoco' ->> 'fim') and minutos(c -> 'almoco' ->> 'ini') < p_ini + p_dur then return false; end if;
  end if;
  select y into b from jsonb_array_elements(coalesce(c -> 'barbeiros', '[]'::jsonb)) y where y ->> 'id' = p_barb limit 1;
  if b is not null and jsonb_typeof(b -> 'folgas') = 'array' and (b -> 'folgas') @> to_jsonb(extract(dow from p_dia)::int) then return false; end if;
  for x in select z from jsonb_array_elements(coalesce(c -> 'bloqueios', '[]'::jsonb)) z loop
    if x ->> 'data' = p_dia::text and (coalesce(x ->> 'barbeiroId', '') = '' or x ->> 'barbeiroId' = p_barb) then
      if coalesce(x ->> 'ini', '') = '' then return false; end if;
      if p_ini < minutos(x ->> 'fim') and minutos(x ->> 'ini') < p_ini + p_dur then return false; end if;
    end if;
  end loop;
  return true;
end $$;

-- ---------- Funções públicas (cliente final, sem login) ----------

-- Um horário está preso se foi marcado, está em andamento/feito, ou aguarda o sinal dentro do prazo.
create or replace function public.segura_horario(d jsonb) returns boolean
language sql stable as $$
  select d ->> 'status' in ('agendado', 'cadeira', 'feito')
      or (d ->> 'status' = 'aguardando_sinal' and coalesce((d ->> 'sinalExpira')::timestamptz, now()) > now());
$$;

-- O sinal só vale se o dono ligou a opção E cadastrou a chave Pix.
create or replace function public.sinal_ativo(c jsonb) returns boolean
language sql immutable as $$
  select coalesce(c -> 'sinal' ->> 'ativo', 'false') = 'true' and coalesce(c -> 'pix' ->> 'chave', '') <> '';
$$;

-- ---------- Mercado Pago (cada barbearia conecta a própria conta) ----------
-- As chaves da conta ficam nesta tabela, que ninguém do navegador consegue ler.
-- Só as funções do servidor (Edge Functions, com a chave service_role) usam.
create table if not exists public.mp_contas (
  barbearia_id uuid primary key references public.barbearias(id) on delete cascade,
  mp_user_id text,
  access_token text not null,
  refresh_token text,
  public_key text,
  expira_em timestamptz,
  live_mode boolean,
  conectado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
alter table public.mp_contas enable row level security;
revoke all on public.mp_contas from anon, authenticated;

-- Código de uso único que liga a volta do Mercado Pago à barbearia certa.
create table if not exists public.mp_estados (
  estado text primary key,
  barbearia_id uuid not null references public.barbearias(id) on delete cascade,
  user_id uuid not null,
  criado_em timestamptz not null default now()
);
alter table public.mp_estados enable row level security;
revoke all on public.mp_estados from anon, authenticated;

-- O que a página do cliente pode usar do Mercado Pago (só a chave pública e as opções).
create or replace function public.mp_online(p_b uuid, c jsonb)
returns json language sql stable security definer set search_path = public as $$
  select case when coalesce(c -> 'mp' ->> 'cartao', 'true') = 'true' or coalesce(c -> 'mp' ->> 'pix', 'true') = 'true' then
    json_build_object(
      'publicKey', m.public_key,
      'cartao', coalesce(c -> 'mp' ->> 'cartao', 'true') = 'true' and m.public_key is not null,
      'pix', coalesce(c -> 'mp' ->> 'pix', 'true') = 'true',
      'parcelas', greatest(1, least(12, coalesce((c -> 'mp' ->> 'parcelas')::int, 1)))) end
  from mp_contas m where m.barbearia_id = p_b;
$$;

-- Sinal ligado: o dono ligou a opção e tem como receber (chave Pix ou Mercado Pago conectado).
create or replace function public.sinal_ligado(p_b uuid, c jsonb)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(c -> 'sinal' ->> 'ativo', 'false') = 'true'
     and (coalesce(c -> 'pix' ->> 'chave', '') <> '' or mp_online(p_b, c) is not null);
$$;

-- Dados que a página de agendamento precisa. Não mostra comissão nem custos.
create or replace function public.barbearia_publica(p_slug text)
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'nome', b.nome,
    'cor', coalesce(b.config ->> 'cor', '#C9A35B'),
    'abre', coalesce(b.config ->> 'abre', '09:00'),
    'fecha', coalesce(b.config ->> 'fecha', '19:00'),
    'intervalo', coalesce((b.config ->> 'intervalo')::int, 30),
    'logo', b.config ->> 'logo',
    'tema', coalesce(b.config ->> 'tema', 'claro'),
    'mensagem', b.config ->> 'mensagem',
    'endereco', b.config ->> 'endereco',
    'instagram', b.config ->> 'instagram',
    'whatsapp', b.config ->> 'whatsapp',
    'formas', coalesce(b.config -> 'formas', '["Pix","Cartão","Dinheiro"]'::jsonb),
    'sinal', case when sinal_ligado(b.id, b.config) then json_build_object(
                'pct', coalesce((b.config -> 'sinal' ->> 'pct')::numeric, 50),
                'prazo', coalesce((b.config -> 'sinal' ->> 'prazo')::int, 30),
                'pixManual', coalesce(b.config -> 'pix' ->> 'chave', '') <> '',
                'online', mp_online(b.id, b.config)) end,
    'servicos', coalesce((select json_agg(json_build_object('id', s ->> 'id', 'nome', s ->> 'nome', 'preco', (s ->> 'preco')::numeric, 'dur', (s ->> 'dur')::int))
                          from jsonb_array_elements(coalesce(b.config -> 'servicos', '[]'::jsonb)) s), '[]'::json),
    'barbeiros', coalesce((select json_agg(json_build_object('id', x ->> 'id', 'nome', x ->> 'nome', 'folgas', coalesce(x -> 'folgas', '[]'::jsonb)))
                          from jsonb_array_elements(coalesce(b.config -> 'barbeiros', '[]'::jsonb)) x), '[]'::json),
    'semana', b.config -> 'semana',
    'almoco', b.config -> 'almoco',
    'bloqueios', coalesce((select json_agg(json_build_object('data', z ->> 'data', 'barbeiroId', z ->> 'barbeiroId', 'ini', z ->> 'ini', 'fim', z ->> 'fim'))
                          from jsonb_array_elements(coalesce(b.config -> 'bloqueios', '[]'::jsonb)) z
                          where z ->> 'data' >= ((now() at time zone 'America/Sao_Paulo')::date)::text), '[]'::json)
  )
  from barbearias b where b.slug = p_slug and barbearia_liberada(b.ativa, b.vencimento);
$$;

-- Horários já ocupados num dia (só barbeiro, hora e duração; nada de nomes).
create or replace function public.horarios_ocupados(p_slug text, p_dia text)
returns json language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object(
           'barbeiroId', r.dados ->> 'barbeiroId',
           'hora', r.dados ->> 'hora',
           'dur', coalesce((r.dados ->> 'dur')::int, 30))), '[]'::json)
  from registros r join barbearias b on b.id = r.barbearia_id
  where b.slug = p_slug and barbearia_liberada(b.ativa, b.vencimento) and r.colecao = 'agendamentos'
    and r.dados ->> 'data' = p_dia
    and segura_horario(r.dados);
$$;

create or replace function public.minutos(h text) returns integer
language sql immutable as $$
  select split_part(h, ':', 1)::int * 60 + split_part(h, ':', 2)::int;
$$;

-- O cliente marca o horário. Confere tudo no servidor pra evitar horário duplicado.
-- Com sinal ligado, o horário fica reservado até o prazo e o dono confirma quando o Pix cair.
create or replace function public.agendar_publico(
  p_slug text, p_dia text, p_hora text, p_servico text, p_barbeiro text, p_nome text, p_tel text)
returns json language plpgsql security definer set search_path = public as $$
declare
  b barbearias%rowtype;
  v_serv jsonb; v_dur int; v_ini int; v_dia date; v_hoje date; v_agora int;
  v_barb jsonb; v_barb_id text; v_tel text; v_cli text; v_id text;
  v_sinal boolean; v_valor numeric; v_expira timestamptz;
begin
  select * into b from barbearias where slug = p_slug and barbearia_liberada(ativa, vencimento);
  if not found then raise exception 'Barbearia não encontrada.'; end if;

  if p_hora !~ '^[0-2][0-9]:[0-5][0-9]$' then raise exception 'Horário inválido.'; end if;
  begin v_dia := p_dia::date; exception when others then raise exception 'Data inválida.'; end;
  v_hoje := (now() at time zone 'America/Sao_Paulo')::date;
  v_agora := extract(hour from now() at time zone 'America/Sao_Paulo')::int * 60 + extract(minute from now() at time zone 'America/Sao_Paulo')::int;
  if v_dia < v_hoje or v_dia > v_hoje + 60 then raise exception 'Escolha uma data entre hoje e os próximos 60 dias.'; end if;
  v_ini := minutos(p_hora);
  if v_dia = v_hoje and v_ini <= v_agora then raise exception 'Esse horário já passou.'; end if;

  if char_length(trim(coalesce(p_nome, ''))) < 2 or char_length(p_nome) > 80 then raise exception 'Informe seu nome.'; end if;
  v_tel := regexp_replace(coalesce(p_tel, ''), '\D', '', 'g');
  if char_length(v_tel) < 10 or char_length(v_tel) > 13 then raise exception 'Informe o WhatsApp com DDD.'; end if;

  select s into v_serv from jsonb_array_elements(coalesce(b.config -> 'servicos', '[]'::jsonb)) s where s ->> 'id' = p_servico limit 1;
  if v_serv is null then raise exception 'Serviço não encontrado.'; end if;
  v_dur := coalesce((v_serv ->> 'dur')::int, 30);
  if expediente(b.config, v_dia) is null or jsonb_typeof(expediente(b.config, v_dia)) <> 'object' then
    raise exception 'A barbearia não abre nesse dia.';
  end if;
  if v_ini < minutos(expediente(b.config, v_dia) ->> 'abre') or v_ini + v_dur > minutos(expediente(b.config, v_dia) ->> 'fecha') then
    raise exception 'Fora do horário de funcionamento.';
  end if;

  -- Uma marcação por vez por barbearia e dia, pra dois clientes não pegarem o mesmo horário.
  perform pg_advisory_xact_lock(hashtext(b.id::text || p_dia));

  v_sinal := sinal_ligado(b.id, b.config);
  if v_sinal and exists (
    select 1 from registros r where r.barbearia_id = b.id and r.colecao = 'agendamentos'
      and r.dados ->> 'status' = 'aguardando_sinal'
      and regexp_replace(coalesce(r.dados ->> 'telefone', ''), '\D', '', 'g') = v_tel
      and coalesce((r.dados ->> 'sinalExpira')::timestamptz, now()) > now()
  ) then
    raise exception 'Você já tem uma reserva esperando o sinal. Pague ou desista dela antes de marcar outra.';
  end if;

  for v_barb in select x from jsonb_array_elements(coalesce(b.config -> 'barbeiros', '[]'::jsonb)) x loop
    if (p_barbeiro = 'qualquer' or v_barb ->> 'id' = p_barbeiro)
       and horario_permitido(b.config, v_dia, v_ini, v_dur, v_barb ->> 'id') and not exists (
      select 1 from registros r
      where r.barbearia_id = b.id and r.colecao = 'agendamentos'
        and r.dados ->> 'data' = p_dia
        and r.dados ->> 'barbeiroId' = v_barb ->> 'id'
        and segura_horario(r.dados)
        and minutos(r.dados ->> 'hora') < v_ini + v_dur
        and v_ini < minutos(r.dados ->> 'hora') + coalesce((r.dados ->> 'dur')::int, 30)
    ) then
      v_barb_id := v_barb ->> 'id';
      exit;
    end if;
  end loop;
  if v_barb_id is null then raise exception 'Esse horário não está mais disponível. Escolha outro.'; end if;

  v_cli := 'c' || v_tel;
  insert into registros (barbearia_id, colecao, id, dados)
    values (b.id, 'clientes', v_cli, jsonb_build_object('nome', trim(p_nome), 'telefone', p_tel, 'criadoEm', now(), 'visitas', 0, 'ultimaVisita', null, 'ficha', ''))
    on conflict (barbearia_id, colecao, id) do update set dados = registros.dados || jsonb_build_object('nome', trim(p_nome));

  v_id := 'w' || replace(gen_random_uuid()::text, '-', '');
  if v_sinal then
    v_valor := round(coalesce((v_serv ->> 'preco')::numeric, 0) * coalesce((b.config -> 'sinal' ->> 'pct')::numeric, 50) / 100, 2);
    v_expira := now() + make_interval(mins => greatest(5, least(240, coalesce((b.config -> 'sinal' ->> 'prazo')::int, 30))));
    if v_valor <= 0 then v_sinal := false; end if;
  end if;

  insert into registros (barbearia_id, colecao, id, dados) values (b.id, 'agendamentos', v_id, jsonb_build_object(
    'data', p_dia, 'hora', p_hora, 'dur', v_dur, 'servicoId', p_servico, 'barbeiroId', v_barb_id,
    'clienteId', v_cli, 'clienteNome', trim(p_nome), 'telefone', p_tel,
    'status', case when v_sinal then 'aguardando_sinal' else 'agendado' end,
    'sinalValor', case when v_sinal then v_valor end,
    'sinalExpira', case when v_sinal then v_expira end,
    'pagOnline', case when v_sinal and mp_online(b.id, b.config) is not null then true end,
    'origem', 'link', 'criadoEm', now()));

  return json_build_object('ok', true, 'id', v_id, 'dia', p_dia, 'hora', p_hora, 'servico', v_serv ->> 'nome',
    'preco', (v_serv ->> 'preco')::numeric,
    'barbeiro', (select x ->> 'nome' from jsonb_array_elements(b.config -> 'barbeiros') x where x ->> 'id' = v_barb_id limit 1),
    'status', case when v_sinal then 'aguardando_sinal' else 'agendado' end,
    'sinal', case when v_sinal then json_build_object('valor', v_valor, 'expira', v_expira,
      'tipo', b.config -> 'pix' ->> 'tipo', 'chave', b.config -> 'pix' ->> 'chave',
      'nome', b.config -> 'pix' ->> 'nome', 'cidade', b.config -> 'pix' ->> 'cidade',
      'online', mp_online(b.id, b.config)) end);
end $$;

-- O cliente acompanha se a barbearia já confirmou o sinal (o id é longo e aleatório).
create or replace function public.status_agendamento(p_slug text, p_id text)
returns json language sql stable security definer set search_path = public as $$
  select json_build_object('status', case when r.dados ->> 'status' = 'aguardando_sinal'
                                          and coalesce((r.dados ->> 'sinalExpira')::timestamptz, now()) <= now()
                                          then 'expirado' else r.dados ->> 'status' end,
                           'dia', r.dados ->> 'data', 'hora', r.dados ->> 'hora')
  from registros r join barbearias b on b.id = r.barbearia_id
  where b.slug = p_slug and r.colecao = 'agendamentos' and r.id = p_id and char_length(p_id) >= 20;
$$;

-- O cliente desiste da reserva antes de pagar, liberando o horário na hora.
create or replace function public.desistir_reserva(p_slug text, p_id text)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  update registros r set dados = r.dados || jsonb_build_object('status', 'cancelado', 'canceladoPor', 'cliente')
  from barbearias b
  where b.id = r.barbearia_id and b.slug = p_slug and r.colecao = 'agendamentos' and r.id = p_id
    and char_length(p_id) >= 20 and r.dados ->> 'status' = 'aguardando_sinal';
  return found;
end $$;

-- ---------- Mercado Pago: funções do dono ----------

-- Mostra no painel se a conta está conectada (nunca devolve as chaves).
create or replace function public.mp_status(p_b uuid)
returns json language plpgsql stable security definer set search_path = public as $$
begin
  if not eh_dono(p_b) then raise exception 'Só o dono vê isso.'; end if;
  return coalesce((select json_build_object('conectado', true, 'conta', m.mp_user_id, 'desde', m.conectado_em,
                                            'teste', coalesce(m.live_mode, true) = false, 'cartao', m.public_key is not null)
                   from mp_contas m where m.barbearia_id = p_b), json_build_object('conectado', false));
end $$;

create or replace function public.mp_desconectar(p_b uuid)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if not eh_dono(p_b) then raise exception 'Só o dono pode desconectar.'; end if;
  delete from mp_contas where barbearia_id = p_b;
  return found;
end $$;

-- ---------- Mercado Pago: funções só do servidor (Edge Functions) ----------

create or replace function public.mp_criar_estado(p_b uuid, p_user uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v text;
begin
  if not exists (select 1 from membros where barbearia_id = p_b and user_id = p_user and papel = 'dono') then
    raise exception 'Só o dono pode conectar o Mercado Pago.';
  end if;
  delete from mp_estados where criado_em < now() - interval '30 minutes';
  v := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  insert into mp_estados (estado, barbearia_id, user_id) values (v, p_b, p_user);
  return v;
end $$;

-- Usa o código uma vez só e devolve de qual barbearia ele é.
create or replace function public.mp_usar_estado(p_estado text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  delete from mp_estados where estado = p_estado and criado_em > now() - interval '30 minutes' returning barbearia_id into v;
  return v;
end $$;

create or replace function public.mp_salvar_conta(p_b uuid, p_user text, p_access text, p_refresh text, p_public text, p_expira timestamptz, p_live boolean)
returns void language sql security definer set search_path = public as $$
  insert into mp_contas (barbearia_id, mp_user_id, access_token, refresh_token, public_key, expira_em, live_mode)
  values (p_b, p_user, p_access, p_refresh, p_public, p_expira, p_live)
  on conflict (barbearia_id) do update set mp_user_id = coalesce(excluded.mp_user_id, mp_contas.mp_user_id),
    access_token = excluded.access_token, refresh_token = coalesce(excluded.refresh_token, mp_contas.refresh_token),
    public_key = coalesce(excluded.public_key, mp_contas.public_key), expira_em = excluded.expira_em,
    live_mode = coalesce(excluded.live_mode, mp_contas.live_mode), atualizado_em = now();
$$;

create or replace function public.mp_conta(p_b uuid)
returns json language sql stable security definer set search_path = public as $$
  select json_build_object('access_token', access_token, 'refresh_token', refresh_token, 'expira_em', expira_em)
  from mp_contas where barbearia_id = p_b;
$$;

-- Tudo que o servidor precisa pra cobrar uma reserva. O valor vem daqui, nunca do navegador.
create or replace function public.mp_cobranca(p_slug text, p_id text)
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'b', b.id, 'barbearia', b.nome, 'status', r.dados ->> 'status',
    'valor', (r.dados ->> 'sinalValor')::numeric, 'expira', r.dados ->> 'sinalExpira',
    'servico', (select s ->> 'nome' from jsonb_array_elements(coalesce(b.config -> 'servicos', '[]'::jsonb)) s where s ->> 'id' = r.dados ->> 'servicoId' limit 1),
    'dia', r.dados ->> 'data', 'hora', r.dados ->> 'hora',
    'mp', r.dados -> 'mp', 'online', mp_online(b.id, b.config),
    'conta', mp_conta(b.id))
  from registros r join barbearias b on b.id = r.barbearia_id
  where b.slug = p_slug and barbearia_liberada(b.ativa, b.vencimento)
    and r.colecao = 'agendamentos' and r.id = p_id and char_length(p_id) >= 20;
$$;

-- Guarda o Pix gerado na reserva e estica a reserva até o Pix vencer.
create or replace function public.mp_registrar(p_b uuid, p_id text, p_mp jsonb, p_expira timestamptz)
returns void language sql security definer set search_path = public as $$
  update registros set dados = dados || jsonb_build_object('mp', coalesce(dados -> 'mp', '{}'::jsonb) || p_mp)
      || case when p_expira is not null and dados ->> 'status' = 'aguardando_sinal'
              then jsonb_build_object('sinalExpira', greatest(coalesce((dados ->> 'sinalExpira')::timestamptz, p_expira), p_expira))
              else '{}'::jsonb end
  where barbearia_id = p_b and colecao = 'agendamentos' and id = p_id;
$$;

-- Pagamento aprovado no Mercado Pago: confirma o horário sozinho.
-- Se a reserva já tinha sido cancelada ou o horário foi pego, marca pra barbearia devolver.
create or replace function public.mp_confirmar(p_b uuid, p_id text, p_valor numeric, p_pagamento text, p_metodo text)
returns text language plpgsql security definer set search_path = public as $$
declare r registros%rowtype; v_ini int; v_dur int; v_choque boolean;
begin
  select * into r from registros where barbearia_id = p_b and colecao = 'agendamentos' and id = p_id;
  if not found then return 'nao_achou'; end if;
  perform pg_advisory_xact_lock(hashtext(p_b::text || (r.dados ->> 'data')));
  select * into r from registros where barbearia_id = p_b and colecao = 'agendamentos' and id = p_id for update;
  if r.dados ->> 'mpPagamento' = p_pagamento then return 'ja_confirmado'; end if;
  if p_valor + 0.01 < coalesce((r.dados ->> 'sinalValor')::numeric, 0) then return 'valor_menor'; end if;

  if r.dados ->> 'status' = 'aguardando_sinal' then
    v_ini := minutos(r.dados ->> 'hora'); v_dur := coalesce((r.dados ->> 'dur')::int, 30);
    select exists (
      select 1 from registros o
      where o.barbearia_id = p_b and o.colecao = 'agendamentos' and o.id <> p_id
        and o.dados ->> 'data' = r.dados ->> 'data' and o.dados ->> 'barbeiroId' = r.dados ->> 'barbeiroId'
        and segura_horario(o.dados)
        and minutos(o.dados ->> 'hora') < v_ini + v_dur and v_ini < minutos(o.dados ->> 'hora') + coalesce((o.dados ->> 'dur')::int, 30)
    ) into v_choque;
    if not v_choque then
      update registros set dados = dados || jsonb_build_object('status', 'agendado', 'sinalPago', p_valor, 'sinalPagoEm', now(),
          'sinalMetodo', p_metodo, 'mpPagamento', p_pagamento)
        where barbearia_id = p_b and colecao = 'agendamentos' and id = p_id;
      return 'confirmado';
    end if;
  end if;

  if r.dados ->> 'status' in ('agendado', 'cadeira', 'feito') and coalesce((r.dados ->> 'sinalPago')::numeric, 0) = 0 then
    update registros set dados = dados || jsonb_build_object('sinalPago', p_valor, 'sinalPagoEm', now(), 'sinalMetodo', p_metodo, 'mpPagamento', p_pagamento)
      where barbearia_id = p_b and colecao = 'agendamentos' and id = p_id;
    return 'confirmado';
  end if;

  update registros set dados = dados || jsonb_build_object('status', case when dados ->> 'status' = 'aguardando_sinal' then 'cancelado' else dados ->> 'status' end,
      'pagoSemHorario', true, 'sinalPago', p_valor, 'sinalPagoEm', now(), 'sinalMetodo', p_metodo, 'mpPagamento', p_pagamento)
    where barbearia_id = p_b and colecao = 'agendamentos' and id = p_id;
  return 'devolver';
end $$;

-- Ninguém do navegador chama as funções do servidor.
do $$
declare f text;
begin
  foreach f in array array[
    'mp_criar_estado(uuid, uuid)', 'mp_usar_estado(text)',
    'mp_salvar_conta(uuid, text, text, text, text, timestamptz, boolean)', 'mp_conta(uuid)',
    'mp_cobranca(text, text)', 'mp_registrar(uuid, text, jsonb, timestamptz)',
    'mp_confirmar(uuid, text, numeric, text, text)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon, authenticated';
    if exists (select 1 from pg_roles where rolname = 'service_role') then
      execute 'grant execute on function public.' || f || ' to service_role';
    end if;
  end loop;
end $$;

-- ---------- Funções do administrador do sistema (você) ----------

create or replace function public.exigir_admin() returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not exists (select 1 from admins where user_id = auth.uid()) then raise exception 'Acesso restrito ao administrador.'; end if;
end $$;

-- Lista todas as barbearias com situação, dono e uso dos últimos 30 dias.
create or replace function public.admin_barbearias()
returns json language plpgsql stable security definer set search_path = public as $$
declare v_hoje date := (now() at time zone 'America/Sao_Paulo')::date; v json;
begin
  perform exigir_admin();
  select coalesce(json_agg(x order by x.criado_em desc), '[]'::json) into v from (
    select b.id, b.nome, b.slug, b.ativa, b.vencimento, b.mensalidade, b.obs_admin, b.criado_em,
      barbearia_liberada(b.ativa, b.vencimento) as liberada,
      (select u.email from membros m join auth.users u on u.id = m.user_id
        where m.barbearia_id = b.id and m.papel = 'dono' order by m.criado_em limit 1) as dono_email,
      (select count(*) from membros m where m.barbearia_id = b.id) as membros,
      (select count(*) from registros r where r.barbearia_id = b.id and r.colecao = 'agendamentos'
        and r.dados ->> 'data' >= (v_hoje - 30)::text) as agendamentos_30d,
      (select count(*) from registros r where r.barbearia_id = b.id and r.colecao = 'comandas'
        and r.dados ->> 'status' = 'fechada' and r.dados ->> 'data' >= (v_hoje - 30)::text) as comandas_30d,
      (select max(r.atualizado_em) from registros r where r.barbearia_id = b.id) as ultima_atividade,
      (select max(p.pago_em) from pagamentos p where p.barbearia_id = b.id) as ultimo_pagamento,
      (select coalesce(sum(p.valor), 0) from pagamentos p where p.barbearia_id = b.id) as total_pago
    from barbearias b
  ) x;
  return v;
end $$;

-- Histórico de pagamentos (de uma barbearia, ou de todas se p_id for nulo).
create or replace function public.admin_pagamentos(p_id uuid default null)
returns json language plpgsql stable security definer set search_path = public as $$
declare v json;
begin
  perform exigir_admin();
  select coalesce(json_agg(json_build_object('id', p.id, 'barbearia_id', p.barbearia_id, 'barbearia', b.nome, 'valor', p.valor,
    'meses', p.meses, 'pago_em', p.pago_em, 'vence_ate', p.vence_ate, 'obs', p.obs) order by p.pago_em desc), '[]'::json)
  into v from pagamentos p join barbearias b on b.id = p.barbearia_id
  where p_id is null or p.barbearia_id = p_id;
  return v;
end $$;

-- Registra uma mensalidade paga: estende o vencimento e libera o acesso.
create or replace function public.admin_registrar_pagamento(p_id uuid, p_valor numeric, p_meses integer, p_obs text default null)
returns date language plpgsql security definer set search_path = public as $$
declare v_hoje date := (now() at time zone 'America/Sao_Paulo')::date; v_venc date; v_novo date;
begin
  perform exigir_admin();
  if coalesce(p_meses, 0) < 1 or p_meses > 24 then raise exception 'Informe de 1 a 24 meses.'; end if;
  if coalesce(p_valor, -1) < 0 then raise exception 'Informe o valor recebido.'; end if;
  select vencimento into v_venc from barbearias where id = p_id;
  if not found then raise exception 'Barbearia não encontrada.'; end if;
  v_novo := (greatest(coalesce(v_venc, v_hoje), v_hoje) + make_interval(months => p_meses))::date;
  update barbearias set vencimento = v_novo, ativa = true where id = p_id;
  insert into pagamentos (barbearia_id, valor, meses, vence_ate, obs) values (p_id, p_valor, p_meses, v_novo, nullif(trim(coalesce(p_obs, '')), ''));
  return v_novo;
end $$;

-- Ajusta manualmente: ativar/desativar, vencimento, mensalidade e anotações.
create or replace function public.admin_salvar_barbearia(p_id uuid, p_ativa boolean, p_vencimento date, p_mensalidade numeric, p_obs text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform exigir_admin();
  update barbearias set ativa = coalesce(p_ativa, ativa), vencimento = p_vencimento,
    mensalidade = p_mensalidade, obs_admin = nullif(trim(coalesce(p_obs, '')), '')
  where id = p_id;
  if not found then raise exception 'Barbearia não encontrada.'; end if;
end $$;

-- Apaga um pagamento lançado errado (não mexe no vencimento; ajuste à mão se precisar).
create or replace function public.admin_apagar_pagamento(p_pagamento uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform exigir_admin();
  delete from pagamentos where id = p_pagamento;
end $$;

-- Apaga a barbearia e tudo dela (agenda, caixa, clientes, pagamentos, Mercado Pago).
-- Também apaga as contas de login da equipe, pra o e-mail poder se cadastrar de novo.
-- Não apaga quem é administrador nem quem também participa de outra barbearia.
-- Pede o nome exato da barbearia como confirmação.
create or replace function public.admin_excluir_barbearia(p_id uuid, p_nome text)
returns json language plpgsql security definer set search_path = public as $$
declare v_nome text; v_users uuid[]; v_emails text[];
begin
  perform exigir_admin();
  select nome into v_nome from barbearias where id = p_id;
  if v_nome is null then raise exception 'Barbearia não encontrada.'; end if;
  if lower(trim(coalesce(p_nome, ''))) <> lower(trim(v_nome)) then
    raise exception 'Digite o nome exato da barbearia pra confirmar.';
  end if;
  select coalesce(array_agg(m.user_id), '{}') into v_users from membros m
  where m.barbearia_id = p_id
    and not exists (select 1 from admins a where a.user_id = m.user_id)
    and not exists (select 1 from membros o where o.user_id = m.user_id and o.barbearia_id <> p_id);
  select coalesce(array_agg(u.email::text), '{}') into v_emails from auth.users u where u.id = any(v_users);
  delete from barbearias where id = p_id;
  delete from auth.users where id = any(v_users);
  return json_build_object('barbearia', v_nome, 'contas_apagadas', v_emails);
end $$;

-- ---------- Permissões das funções ----------
revoke all on function public.criar_barbearia(text, text, jsonb) from public, anon;
revoke all on function public.entrar_por_convite() from public, anon;
grant execute on function public.criar_barbearia(text, text, jsonb) to authenticated;
grant execute on function public.entrar_por_convite() to authenticated;
grant execute on function public.barbearia_publica(text) to anon, authenticated;
grant execute on function public.horarios_ocupados(text, text) to anon, authenticated;
grant execute on function public.agendar_publico(text, text, text, text, text, text, text) to anon, authenticated;
grant execute on function public.status_agendamento(text, text) to anon, authenticated;
revoke all on function public.equipe_acessos(uuid) from public, anon;
revoke all on function public.equipe_ajustar(uuid, uuid, text, text) from public, anon;
grant execute on function public.equipe_acessos(uuid) to authenticated;
grant execute on function public.equipe_ajustar(uuid, uuid, text, text) to authenticated;
grant execute on function public.desistir_reserva(text, text) to anon, authenticated;
revoke all on function public.exigir_admin() from public, anon;
revoke all on function public.admin_barbearias() from public, anon;
revoke all on function public.admin_pagamentos(uuid) from public, anon;
revoke all on function public.admin_registrar_pagamento(uuid, numeric, integer, text) from public, anon;
revoke all on function public.admin_salvar_barbearia(uuid, boolean, date, numeric, text) from public, anon;
revoke all on function public.admin_apagar_pagamento(uuid) from public, anon;
revoke all on function public.admin_excluir_barbearia(uuid, text) from public, anon;
grant execute on function public.admin_excluir_barbearia(uuid, text) to authenticated;
grant execute on function public.eh_admin() to authenticated;
grant execute on function public.exigir_admin() to authenticated;
grant execute on function public.admin_barbearias() to authenticated;
grant execute on function public.admin_pagamentos(uuid) to authenticated;
grant execute on function public.admin_registrar_pagamento(uuid, numeric, integer, text) to authenticated;
grant execute on function public.admin_salvar_barbearia(uuid, boolean, date, numeric, text) to authenticated;
grant execute on function public.admin_apagar_pagamento(uuid) to authenticated;

-- ---------- Tempo real (atualiza as telas de todo mundo na hora) ----------
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    begin alter publication supabase_realtime add table public.registros; exception when duplicate_object then null; end;
    begin alter publication supabase_realtime add table public.barbearias; exception when duplicate_object then null; end;
  end if;
end $$;
