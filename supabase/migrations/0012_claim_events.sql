-- Migration 0012: claim events register (module 1 of the claims and forensic analysis work).
-- Principles: selecting an event never means a valid claim; classifications are provisional;
-- an event becomes final only after a named reviewer approves it with a written note; final events are locked.

create table public.claim_event_types (
  code text primary key,
  category text not null check (category in ('A','B','C','D','E','F')),
  position int not null,
  name_en text not null,
  name_fr text not null
);
insert into public.claim_event_types (code, category, position, name_en, name_fr) values
('A01','A',1,'Late site possession','Remise tardive du site'),
('A02','A',2,'Delayed access to work areas','Accès tardif aux zones de travail'),
('A03','A',3,'Late issuance of drawings','Émission tardive des plans'),
('A04','A',4,'Late approval of drawings','Approbation tardive des plans'),
('A05','A',5,'Late approval of materials','Approbation tardive des matériaux'),
('A06','A',6,'Delayed responses to RFIs','Réponses tardives aux demandes d''information'),
('A07','A',7,'Delayed Engineer''s instructions','Instructions tardives de l''Ingénieur'),
('A08','A',8,'Late payment','Paiement tardif'),
('A09','A',9,'Delayed interim payment certificates','Certificats de paiement intermédiaires tardifs'),
('A10','A',10,'Delayed advance payment','Paiement d''avance tardif'),
('A11','A',11,'Employer-requested changes','Changements demandés par le Maître d''ouvrage'),
('A12','A',12,'Variations and additional works','Modifications et travaux supplémentaires'),
('A13','A',13,'Changes to specifications','Changements des spécifications'),
('A14','A',14,'Changes in scope','Changements de périmètre'),
('A15','A',15,'Suspension instructed by Employer','Suspension ordonnée par le Maître d''ouvrage'),
('A16','A',16,'Delayed testing and commissioning','Essais et mise en service retardés'),
('A17','A',17,'Delayed taking-over','Réception retardée'),
('A18','A',18,'Employer interference','Ingérence du Maître d''ouvrage'),
('A19','A',19,'Late provision of Employer-supplied materials or equipment','Fourniture tardive de matériaux ou d''équipements par le Maître d''ouvrage'),
('B01','B',1,'Late technical decisions','Décisions techniques tardives'),
('B02','B',2,'Delayed approvals','Approbations tardives'),
('B03','B',3,'Conflicting instructions','Instructions contradictoires'),
('B04','B',4,'Incomplete drawings','Plans incomplets'),
('B05','B',5,'Design coordination problems','Problèmes de coordination de la conception'),
('B06','B',6,'Repeated design revisions','Révisions de conception répétées'),
('B07','B',7,'Late inspections','Inspections tardives'),
('B08','B',8,'Delayed certification','Certification tardive'),
('B09','B',9,'Incorrect instructions','Instructions incorrectes'),
('B10','B',10,'Inconsistent technical requirements','Exigences techniques incohérentes'),
('C01','C',1,'Unforeseen physical conditions','Conditions physiques imprévisibles'),
('C02','C',2,'Differing ground conditions','Conditions de sol différentes'),
('C03','C',3,'Underground obstructions','Obstacles souterrains'),
('C04','C',4,'Unforeseen utilities','Réseaux imprévus'),
('C05','C',5,'Adverse climatic conditions','Conditions climatiques défavorables'),
('C06','C',6,'Exceptional weather events','Événements météorologiques exceptionnels'),
('C07','C',7,'Changes in law','Changements de législation'),
('C08','C',8,'Import restrictions','Restrictions à l''importation'),
('C09','C',9,'Government intervention','Intervention du gouvernement'),
('C10','C',10,'Exceptional events under the contract','Événements exceptionnels au sens du contrat'),
('C11','C',11,'Force majeure-type events where applicable','Événements de type force majeure le cas échéant'),
('C12','C',12,'Supply chain disruptions','Perturbations de la chaîne d''approvisionnement'),
('C13','C',13,'Material shortages','Pénuries de matériaux'),
('D01','D',1,'Late procurement','Approvisionnement tardif'),
('D02','D',2,'Late subcontractor mobilisation','Mobilisation tardive des sous-traitants'),
('D03','D',3,'Insufficient labour','Main-d''œuvre insuffisante'),
('D04','D',4,'Insufficient equipment','Équipement insuffisant'),
('D05','D',5,'Poor productivity','Faible productivité'),
('D06','D',6,'Rework','Reprise des travaux'),
('D07','D',7,'Defective works','Travaux défectueux'),
('D08','D',8,'Poor sequencing','Mauvais séquencement'),
('D09','D',9,'Inadequate planning','Planification inadéquate'),
('D10','D',10,'Late submissions','Soumissions tardives'),
('D11','D',11,'Delayed method statements','Méthodes d''exécution tardives'),
('D12','D',12,'Failure to comply with instructions','Non-respect des instructions'),
('D13','D',13,'Cash flow constraints','Contraintes de trésorerie'),
('D14','D',14,'Contractor design delays','Retards de conception de l''Entrepreneur'),
('D15','D',15,'Contractor-responsible critical path delays','Retards sur le chemin critique imputables à l''Entrepreneur'),
('E01','E',1,'Restricted working areas','Zones de travail restreintes'),
('E02','E',2,'Trade stacking','Superposition des corps de métier'),
('E03','E',3,'Congestion','Congestion du chantier'),
('E04','E',4,'Out-of-sequence working','Travail hors séquence'),
('E05','E',5,'Multiple interruptions','Interruptions multiples'),
('E06','E',6,'Excessive overtime','Heures supplémentaires excessives'),
('E07','E',7,'Shift changes','Changements d''équipes'),
('E08','E',8,'Repeated mobilisation and demobilisation','Mobilisations et démobilisations répétées'),
('E09','E',9,'Idle labour','Main-d''œuvre inactive'),
('E10','E',10,'Idle equipment','Équipement inactif'),
('E11','E',11,'Reduced productivity','Productivité réduite'),
('E12','E',12,'Rework and abortive work','Reprises et travaux abandonnés'),
('E13','E',13,'Unplanned acceleration','Accélération non planifiée'),
('E14','E',14,'Inefficient working conditions','Conditions de travail inefficaces'),
('F01','F',1,'Delayed payment','Paiement retardé'),
('F02','F',2,'Delayed certification','Certification retardée'),
('F03','F',3,'Unpaid variations','Modifications impayées'),
('F04','F',4,'Unpaid additional works','Travaux supplémentaires impayés'),
('F05','F',5,'Price escalation','Hausse des prix'),
('F06','F',6,'Increased material costs','Hausse du coût des matériaux'),
('F07','F',7,'Increased labour costs','Hausse du coût de la main-d''œuvre'),
('F08','F',8,'Increased plant costs','Hausse du coût du matériel'),
('F09','F',9,'Currency fluctuations where recoverable','Fluctuations de change si recouvrables'),
('F10','F',10,'Additional financing costs','Frais de financement supplémentaires'),
('F11','F',11,'Extended insurance','Assurance prolongée'),
('F12','F',12,'Extended guarantees and bonds','Garanties et cautions prolongées'),
('F13','F',13,'Additional site overheads','Frais généraux de chantier supplémentaires');
alter table public.claim_event_types enable row level security;
create policy claim_types_read on public.claim_event_types for select to authenticated using (true);
grant select on public.claim_event_types to authenticated;

create table public.claim_events (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  ref text not null,
  event_type text references public.claim_event_types(code),
  custom_title text,
  category text not null check (category in ('A','B','C','D','E','F')),
  occurred_on date,
  notified_on date,
  resolved_on date,
  ongoing boolean not null default false,
  responsible_party text check (responsible_party in ('employer','engineer','contractor','shared','external','unknown')),
  affected_section text,
  description text,
  evidence text,
  classification text not null default 'further_investigation' check (classification in (
    'potentially_compensable','potentially_excusable_non_compensable','contractor_responsible',
    'shared_responsibility','further_investigation','no_demonstrated_entitlement')),
  status text not null default 'identified' check (status in ('identified','under_review','final')),
  review_note text,
  reviewed_by uuid references public.profiles(id),
  reviewed_at timestamptz,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (project_id, ref),
  check (event_type is not null or (custom_title is not null and length(trim(custom_title)) > 0))
);
create index on public.claim_events (project_id, status);

create or replace function public.claim_events_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare t public.claim_event_types;
begin
  if new.event_type is not null then
    select * into t from public.claim_event_types where code = new.event_type;
    new.category := t.category;
  end if;
  if new.ongoing then new.resolved_on := null; end if;
  if new.resolved_on is not null and new.occurred_on is not null and new.resolved_on < new.occurred_on then
    raise exception 'The resolution date cannot be before the date of occurrence';
  end if;
  if new.notified_on is not null and new.occurred_on is not null and new.notified_on < new.occurred_on then
    raise exception 'The notification date cannot be before the date of occurrence';
  end if;

  if tg_op = 'INSERT' then
    new.ref := public.next_ref(new.project_id, 'CLM');
    new.created_by := auth.uid();
    new.status := 'identified'; new.classification := 'further_investigation';
    new.review_note := null; new.reviewed_by := null; new.reviewed_at := null;
    return new;
  end if;

  new.updated_at := now();
  if old.status = 'final' then
    raise exception 'A final claim event is locked. Record a new event instead.';
  end if;
  if new.project_id is distinct from old.project_id or new.ref is distinct from old.ref then
    raise exception 'Reference and project cannot be changed';
  end if;
  if new.status = 'final' then
    if not public.has_project_role(new.project_id, array['project_administrator','project_manager','contract_manager']) then
      raise exception 'Only a Project Manager, Contract Manager or Project Administrator can mark an event final';
    end if;
    if new.review_note is null or length(trim(new.review_note)) < 10 then
      raise exception 'Write a review note of at least 10 characters before marking an event final';
    end if;
    new.reviewed_by := auth.uid(); new.reviewed_at := now();
  else
    new.reviewed_by := null; new.reviewed_at := null;
  end if;
  return new;
end $$;
create trigger claim_events_guard before insert or update on public.claim_events
  for each row execute function public.claim_events_guard();
create trigger claim_events_no_delete before delete on public.claim_events
  for each row execute function public.block_change();
create trigger audit_claim_events after insert or update on public.claim_events
  for each row execute function public.audit_row();

alter table public.claim_events enable row level security;
create policy claim_events_read on public.claim_events for select to authenticated using (public.is_project_member(project_id));
create policy claim_events_insert on public.claim_events for insert to authenticated
  with check (public.has_project_role(project_id, array['project_administrator','project_manager','assistant_project_manager','contract_manager','engineer','site_engineer','quantity_surveyor','planning_engineer','contractor_rep']));
create policy claim_events_update on public.claim_events for update to authenticated
  using (public.has_project_role(project_id, array['project_administrator','project_manager','assistant_project_manager','contract_manager','engineer','site_engineer','quantity_surveyor','planning_engineer','contractor_rep']))
  with check (public.has_project_role(project_id, array['project_administrator','project_manager','assistant_project_manager','contract_manager','engineer','site_engineer','quantity_surveyor','planning_engineer','contractor_rep']));
grant select, insert, update on public.claim_events to authenticated;

revoke execute on function public.claim_events_guard() from public, anon, authenticated;

-- Applied live as 0012 claim_events (see also 0013).
