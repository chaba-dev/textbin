--
-- PostgreSQL database dump
--

\restrict pBrhubflvQFSAQmw9Y79H195OScSjK8sjuilkYsrsEP1DvqhuFtyrR9z2yp0qMb

-- Dumped from database version 17.10
-- Dumped by pg_dump version 17.10

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
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
-- Name: pastes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pastes (
    id uuid NOT NULL,
    data text,
    inserted_at timestamp(3) without time zone NOT NULL,
    updated_at timestamp(3) without time zone NOT NULL,
    syntax_highlight text DEFAULT 'plain'::text NOT NULL,
    user_id uuid NOT NULL,
    expires_at timestamp(3) without time zone DEFAULT NULL::timestamp without time zone,
    visibility character varying(255) DEFAULT 'private'::character varying NOT NULL,
    storage_key character varying(255),
    size_bytes bigint,
    sha256 bytea,
    content_type character varying(255) DEFAULT 'text/plain'::character varying NOT NULL,
    CONSTRAINT pastes_content_location_check CHECK (((data IS NOT NULL) OR (storage_key IS NOT NULL))),
    CONSTRAINT pastes_visibility_check CHECK (((visibility)::text = ANY ((ARRAY['private'::character varying, 'unlisted'::character varying, 'public'::character varying])::text[])))
);


--
-- Name: pending_uploads; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pending_uploads (
    storage_key character varying(255) NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    claimed_at timestamp(6) without time zone
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
-- Name: pastes_expires_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pastes_expires_at_index ON public.pastes USING btree (expires_at);


--
-- Name: pastes_storage_key_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX pastes_storage_key_index ON public.pastes USING btree (storage_key) WHERE (storage_key IS NOT NULL);


--
-- Name: pastes_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pastes_user_id_index ON public.pastes USING btree (user_id);


--
-- Name: pastes_visibility_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pastes_visibility_index ON public.pastes USING btree (visibility);


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
-- Name: pastes pastes_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pastes
    ADD CONSTRAINT pastes_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: users_tokens users_tokens_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users_tokens
    ADD CONSTRAINT users_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

\unrestrict pBrhubflvQFSAQmw9Y79H195OScSjK8sjuilkYsrsEP1DvqhuFtyrR9z2yp0qMb

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
