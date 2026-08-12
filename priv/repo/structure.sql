--
-- PostgreSQL database dump
--

\restrict dJVOKoMBuJRYL7ewkaq6exQNQWvnGPgRkQj3yXGVea6LJjwJkqJLZT2PJ3KUBps

-- Dumped from database version 17.10
-- Dumped by pg_dump version 17.10

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'SQL_ASCII';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: citext; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS citext WITH SCHEMA public;


--
-- Name: EXTENSION citext; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION citext IS 'data type for case-insensitive character strings';


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: organization_memberships; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.organization_memberships (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    user_id uuid NOT NULL,
    role character varying(255) NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    CONSTRAINT organization_memberships_role_check CHECK (((role)::text = ANY ((ARRAY['owner'::character varying, 'admin'::character varying, 'member'::character varying])::text[])))
);


--
-- Name: organizations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.organizations (
    id uuid NOT NULL,
    name character varying(255) NOT NULL,
    slug character varying(255) NOT NULL,
    kind character varying(255) NOT NULL,
    personal_owner_id uuid,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    CONSTRAINT organizations_kind_check CHECK (((kind)::text = ANY ((ARRAY['personal'::character varying, 'team'::character varying])::text[]))),
    CONSTRAINT organizations_personal_owner_check CHECK (((((kind)::text = 'personal'::text) AND (personal_owner_id IS NOT NULL)) OR (((kind)::text = 'team'::text) AND (personal_owner_id IS NULL))))
);


--
-- Name: pastes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pastes (
    id uuid NOT NULL,
    data text,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    syntax_highlight text DEFAULT 'plain'::text NOT NULL,
    expires_at timestamp(3) without time zone DEFAULT NULL::timestamp without time zone,
    visibility character varying(255) DEFAULT 'private'::character varying NOT NULL,
    storage_key character varying(255),
    size_bytes bigint,
    sha256 bytea,
    content_type character varying(255) DEFAULT 'text/plain'::character varying NOT NULL,
    workspace_id uuid NOT NULL,
    created_by_user_id uuid,
    CONSTRAINT pastes_content_location_check CHECK (((data IS NOT NULL) OR (storage_key IS NOT NULL))),
    CONSTRAINT pastes_visibility_check CHECK (((visibility)::text = ANY ((ARRAY['private'::character varying, 'unlisted'::character varying, 'public'::character varying])::text[])))
);


--
-- Name: pending_uploads; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pending_uploads (
    storage_key character varying(255) NOT NULL,
    claimed_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version bigint NOT NULL,
    inserted_at timestamp(0) without time zone
);


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id uuid NOT NULL,
    email public.citext NOT NULL,
    hashed_password character varying(255),
    confirmed_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    default_paste_ttl character varying(255) DEFAULT 'never'::character varying NOT NULL,
    kind character varying(255) DEFAULT 'registered'::character varying NOT NULL
);


--
-- Name: users_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users_tokens (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    token bytea NOT NULL,
    context character varying(255) NOT NULL,
    sent_to character varying(255),
    authenticated_at timestamp(0) without time zone,
    expires_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    name character varying(255),
    last_used_at timestamp(0) without time zone
);


--
-- Name: workspace_memberships; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.workspace_memberships (
    id uuid NOT NULL,
    workspace_id uuid NOT NULL,
    user_id uuid NOT NULL,
    created_by_id uuid,
    role character varying(255) NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    CONSTRAINT workspace_memberships_role_check CHECK (((role)::text = ANY ((ARRAY['owner'::character varying, 'member'::character varying])::text[])))
);


--
-- Name: workspaces; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.workspaces (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    created_by_id uuid,
    name character varying(255) NOT NULL,
    slug character varying(255) NOT NULL,
    visibility character varying(255) DEFAULT 'open'::character varying NOT NULL,
    is_default boolean DEFAULT false NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    CONSTRAINT workspaces_default_visibility_check CHECK (((NOT is_default) OR ((visibility)::text = 'open'::text))),
    CONSTRAINT workspaces_visibility_check CHECK (((visibility)::text = ANY ((ARRAY['open'::character varying, 'private'::character varying])::text[])))
);


--
-- Name: organization_memberships organization_memberships_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_memberships
    ADD CONSTRAINT organization_memberships_pkey PRIMARY KEY (id);


--
-- Name: organizations organizations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organizations
    ADD CONSTRAINT organizations_pkey PRIMARY KEY (id);


--
-- Name: pastes pastes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pastes
    ADD CONSTRAINT pastes_pkey PRIMARY KEY (id);


--
-- Name: pending_uploads pending_uploads_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pending_uploads
    ADD CONSTRAINT pending_uploads_pkey PRIMARY KEY (storage_key);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: users_tokens users_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users_tokens
    ADD CONSTRAINT users_tokens_pkey PRIMARY KEY (id);


--
-- Name: workspace_memberships workspace_memberships_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_memberships
    ADD CONSTRAINT workspace_memberships_pkey PRIMARY KEY (id);


--
-- Name: workspaces workspaces_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspaces
    ADD CONSTRAINT workspaces_pkey PRIMARY KEY (id);


--
-- Name: organization_memberships_organization_id_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX organization_memberships_organization_id_user_id_index ON public.organization_memberships USING btree (organization_id, user_id);


--
-- Name: organization_memberships_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX organization_memberships_user_id_index ON public.organization_memberships USING btree (user_id);


--
-- Name: organizations_personal_owner_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX organizations_personal_owner_id_index ON public.organizations USING btree (personal_owner_id);


--
-- Name: organizations_slug_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX organizations_slug_index ON public.organizations USING btree (slug);


--
-- Name: pastes_created_by_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pastes_created_by_user_id_index ON public.pastes USING btree (created_by_user_id);


--
-- Name: pastes_expires_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pastes_expires_at_index ON public.pastes USING btree (expires_at);


--
-- Name: pastes_storage_key_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX pastes_storage_key_index ON public.pastes USING btree (storage_key) WHERE (storage_key IS NOT NULL);


--
-- Name: pastes_visibility_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pastes_visibility_index ON public.pastes USING btree (visibility);


--
-- Name: pastes_workspace_id_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pastes_workspace_id_inserted_at_index ON public.pastes USING btree (workspace_id, inserted_at);


--
-- Name: pending_uploads_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pending_uploads_inserted_at_index ON public.pending_uploads USING btree (inserted_at);


--
-- Name: users_email_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX users_email_index ON public.users USING btree (email);


--
-- Name: users_kind_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX users_kind_index ON public.users USING btree (kind);


--
-- Name: users_tokens_context_token_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX users_tokens_context_token_index ON public.users_tokens USING btree (context, token);


--
-- Name: users_tokens_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX users_tokens_user_id_index ON public.users_tokens USING btree (user_id);


--
-- Name: workspace_memberships_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX workspace_memberships_user_id_index ON public.workspace_memberships USING btree (user_id);


--
-- Name: workspace_memberships_workspace_id_role_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX workspace_memberships_workspace_id_role_index ON public.workspace_memberships USING btree (workspace_id, role);


--
-- Name: workspace_memberships_workspace_id_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX workspace_memberships_workspace_id_user_id_index ON public.workspace_memberships USING btree (workspace_id, user_id);


--
-- Name: workspaces_one_default_per_organization; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX workspaces_one_default_per_organization ON public.workspaces USING btree (organization_id) WHERE is_default;


--
-- Name: workspaces_organization_id_slug_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX workspaces_organization_id_slug_index ON public.workspaces USING btree (organization_id, slug);


--
-- Name: organization_memberships organization_memberships_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_memberships
    ADD CONSTRAINT organization_memberships_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: organization_memberships organization_memberships_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_memberships
    ADD CONSTRAINT organization_memberships_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: organizations organizations_personal_owner_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organizations
    ADD CONSTRAINT organizations_personal_owner_id_fkey FOREIGN KEY (personal_owner_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: pastes pastes_created_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pastes
    ADD CONSTRAINT pastes_created_by_user_id_fkey FOREIGN KEY (created_by_user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: pastes pastes_workspace_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pastes
    ADD CONSTRAINT pastes_workspace_id_fkey FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE RESTRICT;


--
-- Name: users_tokens users_tokens_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users_tokens
    ADD CONSTRAINT users_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: workspace_memberships workspace_memberships_created_by_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_memberships
    ADD CONSTRAINT workspace_memberships_created_by_id_fkey FOREIGN KEY (created_by_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: workspace_memberships workspace_memberships_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_memberships
    ADD CONSTRAINT workspace_memberships_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: workspace_memberships workspace_memberships_workspace_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspace_memberships
    ADD CONSTRAINT workspace_memberships_workspace_id_fkey FOREIGN KEY (workspace_id) REFERENCES public.workspaces(id) ON DELETE CASCADE;


--
-- Name: workspaces workspaces_created_by_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspaces
    ADD CONSTRAINT workspaces_created_by_id_fkey FOREIGN KEY (created_by_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: workspaces workspaces_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workspaces
    ADD CONSTRAINT workspaces_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

\unrestrict dJVOKoMBuJRYL7ewkaq6exQNQWvnGPgRkQj3yXGVea6LJjwJkqJLZT2PJ3KUBps

INSERT INTO public."schema_migrations" (version) VALUES (20260706061942);
INSERT INTO public."schema_migrations" (version) VALUES (20260709081001);
INSERT INTO public."schema_migrations" (version) VALUES (20260715060411);
INSERT INTO public."schema_migrations" (version) VALUES (20260715070000);
INSERT INTO public."schema_migrations" (version) VALUES (20260716080000);
INSERT INTO public."schema_migrations" (version) VALUES (20260716090000);
INSERT INTO public."schema_migrations" (version) VALUES (20260716093000);
INSERT INTO public."schema_migrations" (version) VALUES (20260716100000);
INSERT INTO public."schema_migrations" (version) VALUES (20260717070000);
INSERT INTO public."schema_migrations" (version) VALUES (20260718070000);
INSERT INTO public."schema_migrations" (version) VALUES (20260805090000);
INSERT INTO public."schema_migrations" (version) VALUES (20260806090000);
INSERT INTO public."schema_migrations" (version) VALUES (20260806100000);
INSERT INTO public."schema_migrations" (version) VALUES (20260810090000);
INSERT INTO public."schema_migrations" (version) VALUES (20260810120000);
