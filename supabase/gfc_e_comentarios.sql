-- Hub da Equipe — tabelas novas: comentários das paralelas e demandas do GFC.
-- Rodar uma vez no Supabase: SQL Editor > New query > colar tudo > Run.
-- Pode ser rodado de novo sem perder dados (usa "if not exists" e recria só as políticas).

-- Quem está logado, pelo e-mail do login, cruzado com o cadastro em "pessoas".
create or replace function public.hub_pessoa_ativa() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.pessoas p
                 where lower(p.email) = lower(auth.jwt() ->> 'email') and p.ativo is not false);
$$;
create or replace function public.hub_pode_gfc() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.pessoas p
                 where lower(p.email) = lower(auth.jwt() ->> 'email') and p.ativo is not false
                   and (p.area = 'gfc' or p.papel in ('coordenador', 'lider') or p.admin is true));
$$;
create or replace function public.hub_minha_pessoa_id() returns text
language sql stable security definer set search_path = public as $$
  select p.id::text from public.pessoas p
  where lower(p.email) = lower(auth.jwt() ->> 'email') and p.ativo is not false limit 1;
$$;

-- 1) Comentários (feed) das atividades paralelas.
--    O tipo de paralela_id acompanha o tipo de paralelas.id (uuid ou outro).
do $$
declare tipo text;
begin
  select format_type(a.atttypid, a.atttypmod) into tipo
  from pg_attribute a where a.attrelid = 'public.paralelas'::regclass and a.attname = 'id';
  execute format($f$
    create table if not exists public.paralela_comentarios (
      id uuid primary key default gen_random_uuid(),
      paralela_id %s not null references public.paralelas(id) on delete cascade,
      autor_id text not null,
      texto text not null check (length(texto) between 1 and 2000),
      criado_em timestamptz not null default now()
    )$f$, tipo);
end $$;
create index if not exists paralela_comentarios_paralela on public.paralela_comentarios(paralela_id);

-- 2) Cadastros do GFC
create table if not exists public.gfc_sites (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  ativo boolean not null default true,
  criado_em timestamptz not null default now()
);
create table if not exists public.gfc_frotas (
  id uuid primary key default gen_random_uuid(),
  site_id uuid not null references public.gfc_sites(id) on delete cascade,
  nome text not null,
  responsavel text,               -- responsável padrão (só o nome; pode ser de fora da equipe)
  ativo boolean not null default true,
  criado_em timestamptz not null default now()
);
create table if not exists public.gfc_responsaveis (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  funcao text,
  criado_em timestamptz not null default now()
);

-- 3) Demandas e seus itens (site/frota)
--    etapas: [{id, titulo, exec: 'terceiro'|'gfc', dias}]  (prazo em dias úteis)
--    passos: {<id da etapa>: {st, enviado_em, concluido_em, dias, resp, obs}}
create table if not exists public.gfc_demandas (
  id uuid primary key default gen_random_uuid(),
  titulo text not null,
  descricao text,
  inicio date not null default current_date,
  responsavel_gfc text,
  etapas jsonb not null default '[]'::jsonb,
  criado_por text,
  criado_em timestamptz not null default now()
);
create table if not exists public.gfc_itens (
  id uuid primary key default gen_random_uuid(),
  demanda_id uuid not null references public.gfc_demandas(id) on delete cascade,
  site_id uuid references public.gfc_sites(id) on delete set null,
  site_nome text,                 -- nomes guardados para o histórico sobreviver à exclusão do cadastro
  frota_id uuid references public.gfc_frotas(id) on delete set null,
  frota_nome text,
  responsavel text,
  obs text,
  passos jsonb not null default '{}'::jsonb,
  criado_em timestamptz not null default now()
);
create index if not exists gfc_itens_demanda on public.gfc_itens(demanda_id);

-- 4) Permissões (RLS)
alter table public.paralela_comentarios enable row level security;
alter table public.gfc_sites enable row level security;
alter table public.gfc_frotas enable row level security;
alter table public.gfc_responsaveis enable row level security;
alter table public.gfc_demandas enable row level security;
alter table public.gfc_itens enable row level security;

-- comentários: toda a equipe lê; cada um escreve em seu nome e apaga só os seus
drop policy if exists coment_ler on public.paralela_comentarios;
drop policy if exists coment_inserir on public.paralela_comentarios;
drop policy if exists coment_apagar on public.paralela_comentarios;
create policy coment_ler on public.paralela_comentarios for select to authenticated using (public.hub_pessoa_ativa());
create policy coment_inserir on public.paralela_comentarios for insert to authenticated with check (autor_id = public.hub_minha_pessoa_id());
create policy coment_apagar on public.paralela_comentarios for delete to authenticated using (autor_id = public.hub_minha_pessoa_id());

-- GFC: área GFC, coordenador, líder técnico e administradores leem e editam
do $$
declare t text;
begin
  foreach t in array array['gfc_sites', 'gfc_frotas', 'gfc_responsaveis', 'gfc_demandas', 'gfc_itens'] loop
    execute format('drop policy if exists gfc_acesso on public.%I', t);
    execute format('create policy gfc_acesso on public.%I for all to authenticated using (public.hub_pode_gfc()) with check (public.hub_pode_gfc())', t);
  end loop;
end $$;
