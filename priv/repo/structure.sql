--
-- PostgreSQL database dump
--

\restrict EY1hQWaolTvOHfEYLGjAbz1Mmf58x4uCcATy51Mx1gHj5XrYoLwxP0oDBqViXqi

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

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: pastes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pastes (
    id uuid NOT NULL,
    content text NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version bigint NOT NULL,
    inserted_at timestamp(0) without time zone
);


--
-- Name: pastes pastes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pastes
    ADD CONSTRAINT pastes_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- PostgreSQL database dump complete
--

\unrestrict EY1hQWaolTvOHfEYLGjAbz1Mmf58x4uCcATy51Mx1gHj5XrYoLwxP0oDBqViXqi

INSERT INTO public."schema_migrations" (version) VALUES (20260706061942);
