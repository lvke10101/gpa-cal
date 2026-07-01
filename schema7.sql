


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

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."comments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "post_id" "uuid" NOT NULL,
    "author_id" "uuid" NOT NULL,
    "body" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "parent_id" "uuid",
    "upvotes" integer DEFAULT 0 NOT NULL,
    "downvotes" integer DEFAULT 0 NOT NULL
);


ALTER TABLE "public"."comments" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."post_comment"("p_post_id" "uuid", "p_body" "text") RETURNS "public"."comments"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE v_uid uuid := auth.uid(); v_row public.comments;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
    PERFORM public.spend_credits(1);
      INSERT INTO public.comments (post_id, author_id, body)
          VALUES (p_post_id, v_uid, p_body)
              RETURNING * INTO v_row;
                RETURN v_row;
                END;
                $$;


ALTER FUNCTION "public"."post_comment"("p_post_id" "uuid", "p_body" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."post_comment"("p_post_id" "uuid", "p_body" "text", "p_parent_id" "uuid" DEFAULT NULL::"uuid") RETURNS "public"."comments"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
        DECLARE
          v_uid uuid := auth.uid();
            v_row public.comments;
            BEGIN
              IF v_uid IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;

                -- If replying, confirm parent belongs to the same post
                  IF p_parent_id IS NOT NULL THEN
                      IF NOT EXISTS (
                            SELECT 1 FROM public.comments
                                  WHERE id = p_parent_id AND post_id = p_post_id
                                      ) THEN
                                            RAISE EXCEPTION 'Invalid parent comment';
                                                END IF;
                                                  END IF;

                                                    PERFORM public.spend_credits(1);

                                                      INSERT INTO public.comments (post_id, author_id, body, parent_id)
                                                        VALUES (p_post_id, v_uid, p_body, p_parent_id)
                                                          RETURNING * INTO v_row;

                                                            RETURN v_row;
                                                            END;
                                                            $$;


ALTER FUNCTION "public"."post_comment"("p_post_id" "uuid", "p_body" "text", "p_parent_id" "uuid") OWNER TO "postgres";


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


CREATE OR REPLACE FUNCTION "public"."unlock_post"("p_post_id" "uuid") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_user_id   uuid := auth.uid();
    v_cost      integer;
      v_balance   integer;
        v_already   boolean;
        BEGIN
          -- Must be logged in
            IF v_user_id IS NULL THEN
                RAISE EXCEPTION 'not_authenticated';
                  END IF;

                    -- Get the post cost; confirm it's actually premium
                      SELECT credit_cost INTO v_cost
                        FROM posts
                          WHERE id = p_post_id AND is_premium = true;

                            IF NOT FOUND THEN
                                RAISE EXCEPTION 'not_premium_or_not_found';
                                  END IF;

                                    -- Check if already unlocked (idempotent)
                                      SELECT EXISTS (
                                          SELECT 1 FROM post_unlocks
                                              WHERE post_id = p_post_id AND user_id = v_user_id
                                                ) INTO v_already;

                                                  IF v_already THEN
                                                      -- Already unlocked — just return current balance
                                                          SELECT balance INTO v_balance FROM credits WHERE id = v_user_id;
                                                              RETURN COALESCE(v_balance, 0);
                                                                END IF;

                                                                  -- Check & deduct credits (uses existing spend_credits function)
                                                                    SELECT spend_credits(v_cost) INTO v_balance;

                                                                      -- Insert unlock record
                                                                        INSERT INTO post_unlocks (post_id, user_id)
                                                                          VALUES (p_post_id, v_user_id);

                                                                            RETURN v_balance;
                                                                            END;
                                                                            $$;


ALTER FUNCTION "public"."unlock_post"("p_post_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
                      BEGIN
                        NEW.updated_at = NOW();
                          RETURN NEW;
                          END;
                          $$;


ALTER FUNCTION "public"."update_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."vote_comment"("p_comment_id" "uuid", "p_vote" smallint) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
      DECLARE
        v_uid      uuid := auth.uid();
          v_existing smallint;
            v_result   jsonb;
            BEGIN
              IF v_uid IS NULL THEN
                  RAISE EXCEPTION 'Not authenticated';
                    END IF;

                      IF p_vote NOT IN (1, -1) THEN
                          RAISE EXCEPTION 'Invalid vote value';
                            END IF;

                              -- Check for existing vote
                                SELECT vote INTO v_existing
                                  FROM public.comment_votes
                                    WHERE comment_id = p_comment_id AND user_id = v_uid;

                                      IF NOT FOUND THEN
                                          -- No prior vote: insert and increment
                                              INSERT INTO public.comment_votes (comment_id, user_id, vote)
                                                  VALUES (p_comment_id, v_uid, p_vote);

                                                      UPDATE public.comments
                                                          SET upvotes   = upvotes   + CASE WHEN p_vote =  1 THEN 1 ELSE 0 END,
                                                                  downvotes = downvotes + CASE WHEN p_vote = -1 THEN 1 ELSE 0 END
                                                                      WHERE id = p_comment_id;

                                                                        ELSIF v_existing = p_vote THEN
                                                                            -- Same vote: toggle off, decrement
                                                                                DELETE FROM public.comment_votes
                                                                                    WHERE comment_id = p_comment_id AND user_id = v_uid;

                                                                                        UPDATE public.comments
                                                                                            SET upvotes   = upvotes   - CASE WHEN p_vote =  1 THEN 1 ELSE 0 END,
                                                                                                    downvotes = downvotes - CASE WHEN p_vote = -1 THEN 1 ELSE 0 END
                                                                                                        WHERE id = p_comment_id;

                                                                                                          ELSE
                                                                                                              -- Opposite vote: update row, swap counters
                                                                                                                  UPDATE public.comment_votes
                                                                                                                      SET vote = p_vote, created_at = now()
                                                                                                                          WHERE comment_id = p_comment_id AND user_id = v_uid;

                                                                                                                              UPDATE public.comments
                                                                                                                                  SET upvotes   = upvotes   + CASE WHEN p_vote =  1 THEN 1 ELSE -1 END,
                                                                                                                                          downvotes = downvotes + CASE WHEN p_vote = -1 THEN 1 ELSE -1 END
                                                                                                                                              WHERE id = p_comment_id;

                                                                                                                                                END IF;

                                                                                                                                                  -- Return updated counts + user's current vote state (null = no vote)
                                                                                                                                                    SELECT jsonb_build_object(
                                                                                                                                                        'upvotes',   c.upvotes,
                                                                                                                                                            'downvotes', c.downvotes,
                                                                                                                                                                'user_vote', cv.vote
                                                                                                                                                                  )
                                                                                                                                                                    INTO v_result
                                                                                                                                                                      FROM public.comments c
                                                                                                                                                                        LEFT JOIN public.comment_votes cv
                                                                                                                                                                            ON cv.comment_id = c.id AND cv.user_id = v_uid
                                                                                                                                                                              WHERE c.id = p_comment_id;

                                                                                                                                                                                RETURN v_result;
                                                                                                                                                                                END;
                                                                                                                                                                                $$;


ALTER FUNCTION "public"."vote_comment"("p_comment_id" "uuid", "p_vote" smallint) OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."avatars" (
    "id" "text" NOT NULL,
    "path" "text" NOT NULL,
    "url" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."avatars" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."bookmarks" (
    "user_id" "uuid" NOT NULL,
    "post_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."bookmarks" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."comment_votes" (
    "comment_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "vote" smallint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "comment_votes_value" CHECK (("vote" = ANY (ARRAY[1, '-1'::integer])))
);


ALTER TABLE "public"."comment_votes" OWNER TO "postgres";


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
    "role" "text" DEFAULT 'student'::"text" NOT NULL,
    "verified" boolean DEFAULT false NOT NULL,
    CONSTRAINT "gpa_data_level_check" CHECK ((("level" >= 1) AND ("level" <= 5))),
    CONSTRAINT "gpa_data_role_check" CHECK (("role" = ANY (ARRAY['student'::"text", 'contributor'::"text", 'admin'::"text"])))
);


ALTER TABLE "public"."gpa_data" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."news_images" (
    "id" "text" NOT NULL,
    "path" "text" NOT NULL,
    "url" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."news_images" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."post_unlocks" (
    "user_id" "uuid" NOT NULL,
    "post_id" "uuid" NOT NULL,
    "unlocked_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."post_unlocks" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."posts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "author_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "body" "text" NOT NULL,
    "tags" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "source_links" "text"[] DEFAULT '{}'::"text"[],
    "comments_restricted" boolean DEFAULT false NOT NULL,
    "is_premium" boolean DEFAULT false NOT NULL,
    "credit_cost" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "image_url" "text"
);


ALTER TABLE "public"."posts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."reactions" (
    "post_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "type" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "reactions_type_check" CHECK (("type" = ANY (ARRAY['like'::"text", 'dislike'::"text"])))
);


ALTER TABLE "public"."reactions" OWNER TO "postgres";


ALTER TABLE ONLY "public"."avatars"
    ADD CONSTRAINT "avatars_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."bookmarks"
    ADD CONSTRAINT "bookmarks_pkey" PRIMARY KEY ("user_id", "post_id");



ALTER TABLE ONLY "public"."comment_votes"
    ADD CONSTRAINT "comment_votes_pkey" PRIMARY KEY ("comment_id", "user_id");



ALTER TABLE ONLY "public"."comments"
    ADD CONSTRAINT "comments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."course_catalogs"
    ADD CONSTRAINT "course_catalogs_department_year_semester_level_key" UNIQUE ("department", "year", "semester", "level");



ALTER TABLE ONLY "public"."course_catalogs"
    ADD CONSTRAINT "course_catalogs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."credits"
    ADD CONSTRAINT "credits_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."gpa_data"
    ADD CONSTRAINT "gpa_data_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."news_images"
    ADD CONSTRAINT "news_images_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."post_unlocks"
    ADD CONSTRAINT "post_unlocks_pkey" PRIMARY KEY ("user_id", "post_id");



ALTER TABLE ONLY "public"."posts"
    ADD CONSTRAINT "posts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."reactions"
    ADD CONSTRAINT "reactions_pkey" PRIMARY KEY ("post_id", "user_id");



CREATE INDEX "comments_parent_id_idx" ON "public"."comments" USING "btree" ("parent_id") WHERE ("parent_id" IS NOT NULL);



CREATE INDEX "comments_post_id_idx" ON "public"."comments" USING "btree" ("post_id");



CREATE OR REPLACE TRIGGER "trg_touch_course_catalogs" BEFORE UPDATE ON "public"."course_catalogs" FOR EACH ROW EXECUTE FUNCTION "public"."touch_course_catalogs_updated_at"();



CREATE OR REPLACE TRIGGER "update_gpa_data_updated_at" BEFORE UPDATE ON "public"."gpa_data" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();



ALTER TABLE ONLY "public"."bookmarks"
    ADD CONSTRAINT "bookmarks_post_id_fkey" FOREIGN KEY ("post_id") REFERENCES "public"."posts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."bookmarks"
    ADD CONSTRAINT "bookmarks_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."comment_votes"
    ADD CONSTRAINT "comment_votes_comment_id_fkey" FOREIGN KEY ("comment_id") REFERENCES "public"."comments"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."comment_votes"
    ADD CONSTRAINT "comment_votes_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."comments"
    ADD CONSTRAINT "comments_author_id_fkey" FOREIGN KEY ("author_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."comments"
    ADD CONSTRAINT "comments_parent_id_fkey" FOREIGN KEY ("parent_id") REFERENCES "public"."comments"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."comments"
    ADD CONSTRAINT "comments_post_id_fkey" FOREIGN KEY ("post_id") REFERENCES "public"."posts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."credits"
    ADD CONSTRAINT "credits_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."gpa_data"
    ADD CONSTRAINT "gpa_data_avatar_id_fkey" FOREIGN KEY ("avatar_id") REFERENCES "public"."avatars"("id");



ALTER TABLE ONLY "public"."post_unlocks"
    ADD CONSTRAINT "post_unlocks_post_id_fkey" FOREIGN KEY ("post_id") REFERENCES "public"."posts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."post_unlocks"
    ADD CONSTRAINT "post_unlocks_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."posts"
    ADD CONSTRAINT "posts_author_id_fkey" FOREIGN KEY ("author_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."reactions"
    ADD CONSTRAINT "reactions_post_id_fkey" FOREIGN KEY ("post_id") REFERENCES "public"."posts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."reactions"
    ADD CONSTRAINT "reactions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



CREATE POLICY "Authenticated users can read course catalogs" ON "public"."course_catalogs" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authors and admins can delete posts" ON "public"."posts" FOR DELETE USING ((("auth"."uid"() = "author_id") OR (EXISTS ( SELECT 1
   FROM "public"."gpa_data"
  WHERE (("gpa_data"."id" = "auth"."uid"()) AND ("gpa_data"."role" = 'admin'::"text"))))));



CREATE POLICY "Authors can update own posts" ON "public"."posts" FOR UPDATE USING (("auth"."uid"() = "author_id"));



CREATE POLICY "Avatars are publicly readable" ON "public"."avatars" FOR SELECT USING (true);



CREATE POLICY "Comment votes are publicly readable" ON "public"."comment_votes" FOR SELECT USING (true);



CREATE POLICY "Comments are publicly readable" ON "public"."comments" FOR SELECT USING (true);



CREATE POLICY "News images are publicly readable" ON "public"."news_images" FOR SELECT USING (true);



CREATE POLICY "Only contributors can insert posts" ON "public"."posts" FOR INSERT WITH CHECK ((("auth"."uid"() = "author_id") AND (EXISTS ( SELECT 1
   FROM "public"."gpa_data"
  WHERE (("gpa_data"."id" = "auth"."uid"()) AND ("gpa_data"."role" = ANY (ARRAY['contributor'::"text", 'admin'::"text"])))))));



CREATE POLICY "Posts are publicly readable" ON "public"."posts" FOR SELECT USING (true);



CREATE POLICY "Public profiles are viewable by all" ON "public"."gpa_data" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Reactions are publicly readable" ON "public"."reactions" FOR SELECT USING (true);



CREATE POLICY "Users can insert own data" ON "public"."gpa_data" FOR INSERT WITH CHECK (("auth"."uid"() = "id"));



CREATE POLICY "Users can update own data" ON "public"."gpa_data" FOR UPDATE USING (("auth"."uid"() = "id"));



CREATE POLICY "Users can view own credits" ON "public"."credits" FOR SELECT USING (("auth"."uid"() = "id"));



CREATE POLICY "Users can view own data" ON "public"."gpa_data" FOR SELECT USING (("auth"."uid"() = "id"));



CREATE POLICY "Users manage own bookmarks" ON "public"."bookmarks" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users manage own comment votes" ON "public"."comment_votes" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users manage own reaction" ON "public"."reactions" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users view own unlocks" ON "public"."post_unlocks" FOR SELECT USING (("auth"."uid"() = "user_id"));



ALTER TABLE "public"."avatars" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."bookmarks" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."comment_votes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."comments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."course_catalogs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."credits" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."gpa_data" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."news_images" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."post_unlocks" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."posts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."reactions" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";


GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";






















































































































































GRANT ALL ON FUNCTION "public"."handle_new_user_credits"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_new_user_credits"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_new_user_credits"() TO "service_role";



GRANT ALL ON TABLE "public"."comments" TO "anon";
GRANT ALL ON TABLE "public"."comments" TO "authenticated";
GRANT ALL ON TABLE "public"."comments" TO "service_role";



GRANT ALL ON FUNCTION "public"."post_comment"("p_post_id" "uuid", "p_body" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."post_comment"("p_post_id" "uuid", "p_body" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."post_comment"("p_post_id" "uuid", "p_body" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."post_comment"("p_post_id" "uuid", "p_body" "text", "p_parent_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."post_comment"("p_post_id" "uuid", "p_body" "text", "p_parent_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."post_comment"("p_post_id" "uuid", "p_body" "text", "p_parent_id" "uuid") TO "service_role";



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



GRANT ALL ON FUNCTION "public"."unlock_post"("p_post_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."unlock_post"("p_post_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."unlock_post"("p_post_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_updated_at"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."vote_comment"("p_comment_id" "uuid", "p_vote" smallint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."vote_comment"("p_comment_id" "uuid", "p_vote" smallint) TO "anon";
GRANT ALL ON FUNCTION "public"."vote_comment"("p_comment_id" "uuid", "p_vote" smallint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vote_comment"("p_comment_id" "uuid", "p_vote" smallint) TO "service_role";


















GRANT ALL ON TABLE "public"."avatars" TO "anon";
GRANT ALL ON TABLE "public"."avatars" TO "authenticated";
GRANT ALL ON TABLE "public"."avatars" TO "service_role";



GRANT ALL ON TABLE "public"."bookmarks" TO "anon";
GRANT ALL ON TABLE "public"."bookmarks" TO "authenticated";
GRANT ALL ON TABLE "public"."bookmarks" TO "service_role";



GRANT ALL ON TABLE "public"."comment_votes" TO "anon";
GRANT ALL ON TABLE "public"."comment_votes" TO "authenticated";
GRANT ALL ON TABLE "public"."comment_votes" TO "service_role";



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



GRANT ALL ON TABLE "public"."news_images" TO "anon";
GRANT ALL ON TABLE "public"."news_images" TO "authenticated";
GRANT ALL ON TABLE "public"."news_images" TO "service_role";



GRANT ALL ON TABLE "public"."post_unlocks" TO "anon";
GRANT ALL ON TABLE "public"."post_unlocks" TO "authenticated";
GRANT ALL ON TABLE "public"."post_unlocks" TO "service_role";



GRANT ALL ON TABLE "public"."posts" TO "anon";
GRANT ALL ON TABLE "public"."posts" TO "authenticated";
GRANT ALL ON TABLE "public"."posts" TO "service_role";



GRANT ALL ON TABLE "public"."reactions" TO "anon";
GRANT ALL ON TABLE "public"."reactions" TO "authenticated";
GRANT ALL ON TABLE "public"."reactions" TO "service_role";









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



































