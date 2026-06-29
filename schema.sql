


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE OR REPLACE FUNCTION "public"."handle_new_user_credits"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
              begin
                insert into public.credits (id, balance)
                  values (new.id, 0);
                    return new;
                    end;
                    $$;


ALTER FUNCTION "public"."handle_new_user_credits"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rls_auto_enable"() RETURNS "event_trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog'
    AS $$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$$;


ALTER FUNCTION "public"."rls_auto_enable"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."spend_credits"("p_cost" integer) RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
      DECLARE
        v_uid uuid := auth.uid();
          v_new_balance integer;
          BEGIN
            IF v_uid IS NULL THEN
                RAISE EXCEPTION 'Not authenticated';
                  END IF;

                    IF p_cost IS NULL OR p_cost <= 0 THEN
                        RAISE EXCEPTION 'Invalid cost';
                          END IF;

                            -- Atomic: only deducts if balance is sufficient, in one statement,
                              -- so two simultaneous spends can't both succeed past a stale read.
                                UPDATE public.credits
                                     SET balance = balance - p_cost,
                                              updated_at = now()
                                                 WHERE id = v_uid
                                                      AND balance >= p_cost
                                                        RETURNING balance INTO v_new_balance;

                                                          IF v_new_balance IS NULL THEN
                                                              RAISE EXCEPTION 'Insufficient credits';
                                                                END IF;

                                                                  RETURN v_new_balance;
                                                                  END;
                                                                  $$;


ALTER FUNCTION "public"."spend_credits"("p_cost" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."touch_course_catalogs_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
                begin
                  new.updated_at = now();
                    return new;
                    end;
                    $$;


ALTER FUNCTION "public"."touch_course_catalogs_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
                      BEGIN
                        NEW.updated_at = NOW();
                          RETURN NEW;
                          END;
                          $$;


ALTER FUNCTION "public"."update_updated_at"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."avatars" (
    "id" "text" NOT NULL,
    "path" "text" NOT NULL,
    "url" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."avatars" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."course_catalogs" (
    "id" bigint NOT NULL,
    "department" "text" NOT NULL,
    "year" integer NOT NULL,
    "semester" "text" NOT NULL,
    "level" integer NOT NULL,
    "courses" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "course_catalogs_level_check" CHECK ((("level" >= 1) AND ("level" <= 5))),
    CONSTRAINT "course_catalogs_semester_check" CHECK (("semester" = ANY (ARRAY['1st'::"text", '2nd'::"text"]))),
    CONSTRAINT "course_catalogs_year_check" CHECK ((("year" >= 2000) AND ("year" <= 2100)))
);


ALTER TABLE "public"."course_catalogs" OWNER TO "postgres";


ALTER TABLE "public"."course_catalogs" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."course_catalogs_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."credits" (
    "id" "uuid" NOT NULL,
    "balance" integer DEFAULT 0 NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."credits" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."gpa_data" (
    "id" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "department" "text",
    "semesters" "jsonb" DEFAULT '{}'::"jsonb",
    "courses" "jsonb" DEFAULT '{}'::"jsonb",
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "notes" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "username" "text",
    "full_name" "text",
    "avatar_id" "text",
    "level" smallint,
    CONSTRAINT "gpa_data_level_check" CHECK ((("level" >= 1) AND ("level" <= 5)))
);


ALTER TABLE "public"."gpa_data" OWNER TO "postgres";


ALTER TABLE ONLY "public"."avatars"
    ADD CONSTRAINT "avatars_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."course_catalogs"
    ADD CONSTRAINT "course_catalogs_department_year_semester_level_key" UNIQUE ("department", "year", "semester", "level");



ALTER TABLE ONLY "public"."course_catalogs"
    ADD CONSTRAINT "course_catalogs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."credits"
    ADD CONSTRAINT "credits_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."gpa_data"
    ADD CONSTRAINT "gpa_data_pkey" PRIMARY KEY ("id");



CREATE OR REPLACE TRIGGER "trg_touch_course_catalogs" BEFORE UPDATE ON "public"."course_catalogs" FOR EACH ROW EXECUTE FUNCTION "public"."touch_course_catalogs_updated_at"();



CREATE OR REPLACE TRIGGER "update_gpa_data_updated_at" BEFORE UPDATE ON "public"."gpa_data" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();



ALTER TABLE ONLY "public"."credits"
    ADD CONSTRAINT "credits_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."gpa_data"
    ADD CONSTRAINT "gpa_data_avatar_id_fkey" FOREIGN KEY ("avatar_id") REFERENCES "public"."avatars"("id");



CREATE POLICY "Authenticated users can read course catalogs" ON "public"."course_catalogs" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Avatars are publicly readable" ON "public"."avatars" FOR SELECT USING (true);



CREATE POLICY "Users can insert own data" ON "public"."gpa_data" FOR INSERT WITH CHECK (("auth"."uid"() = "id"));



CREATE POLICY "Users can update own data" ON "public"."gpa_data" FOR UPDATE USING (("auth"."uid"() = "id"));



CREATE POLICY "Users can view own credits" ON "public"."credits" FOR SELECT USING (("auth"."uid"() = "id"));



CREATE POLICY "Users can view own data" ON "public"."gpa_data" FOR SELECT USING (("auth"."uid"() = "id"));



ALTER TABLE "public"."avatars" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."course_catalogs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."credits" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."gpa_data" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";


GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";






















































































































































GRANT ALL ON FUNCTION "public"."handle_new_user_credits"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_new_user_credits"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_new_user_credits"() TO "service_role";



GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "anon";
GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."spend_credits"("p_cost" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."spend_credits"("p_cost" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."spend_credits"("p_cost" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."spend_credits"("p_cost" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."touch_course_catalogs_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."touch_course_catalogs_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."touch_course_catalogs_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_updated_at"() TO "service_role";


















GRANT ALL ON TABLE "public"."avatars" TO "anon";
GRANT ALL ON TABLE "public"."avatars" TO "authenticated";
GRANT ALL ON TABLE "public"."avatars" TO "service_role";



GRANT ALL ON TABLE "public"."course_catalogs" TO "anon";
GRANT ALL ON TABLE "public"."course_catalogs" TO "authenticated";
GRANT ALL ON TABLE "public"."course_catalogs" TO "service_role";



GRANT ALL ON SEQUENCE "public"."course_catalogs_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."course_catalogs_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."course_catalogs_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."credits" TO "anon";
GRANT ALL ON TABLE "public"."credits" TO "authenticated";
GRANT ALL ON TABLE "public"."credits" TO "service_role";



GRANT ALL ON TABLE "public"."gpa_data" TO "anon";
GRANT ALL ON TABLE "public"."gpa_data" TO "authenticated";
GRANT ALL ON TABLE "public"."gpa_data" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";



































