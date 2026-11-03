# frozen_string_literal: true

module ::RobotMcp
  module Tools
    READ_ONLY = {
      readOnlyHint: true,
      destructiveHint: false,
      idempotentHint: true,
      openWorldHint: false,
    }.freeze
    WRITE = {
      readOnlyHint: false,
      destructiveHint: false,
      idempotentHint: false,
      openWorldHint: false,
    }.freeze
    MAX_READ_LENGTH = 50_000

    DOCUMENT_INSTRUCTIONS = <<~TEXT
      Dokumentuj u IT-Wiki (forum.robot.ba) ono što je urađeno u ovoj sesiji.

      1. Prvo pozovi robot_search da vidiš postoji li već tema za taj server, lokaciju ili sistem.
         Ako postoji, predloži dopunu (robot_wiki_reply), inače novu temu (robot_wiki_create_topic).
      2. Piši na bosanskom, jasno, za kolegu iz IT-a koji za godinu dana treba ponoviti ili provjeriti posao.
      3. Obrazac:
         **Ukratko:** 2-3 rečenice šta je urađeno i zašto.
         ## Okruženje
         Serveri, IP adrese, lokacije, verzije.
         ## Šta je urađeno
         Koraci redom, komande i konfiguracije u blokovima koda.
         ## Kako provjeriti / vratiti
         ## Otvorene stavke
         Lista sa [ ] za ono što je ostalo.
      4. NIKAD ne upisuj lozinke, ključeve, tokene ni connection stringove sa lozinkom.
         Umjesto vrijednosti napiši "lozinka: u trezoru".
      5. Prije objave pozovi robot_check_secrets, pa korisniku pokaži cijeli nacrt i gdje ide
         (nova tema sa naslovom ili dopuna postojeće). Objavi tek kad korisnik potvrdi.
      6. Korisnička imena ne piši sa @ (to šalje obavijesti i poziva AI botove), osim ako korisnik to izričito traži.
    TEXT

    module_function

    def register!(plugin)
      plugin.register_mcp_tool(
        "robot_search",
        title: "Pretraga IT dokumentacije",
        description:
          "Pretražuje IT-Wiki i ostale dozvoljene IT kategorije foruma. Vraća teme sa kratkim izvodom. " \
            "Koristi prije pisanja dokumentacije da nađeš postojeću temu.",
        implementation: Search,
        input_schema:
          object_schema(
            {
              query: {
                type: "string",
                minLength: 1,
                maxLength: 500,
              },
              max_results: {
                type: "integer",
                minimum: 1,
                maximum: 20,
              },
            },
            required: %w[query],
          ),
        output_schema: Search::OUTPUT_SCHEMA,
        required_scopes: Search::REQUIRED_SCOPES,
        annotations: READ_ONLY,
      )

      plugin.register_mcp_tool(
        "robot_read_topic",
        title: "Čitanje teme",
        description: "Čita postove teme iz IT-Wiki ili druge dozvoljene IT kategorije.",
        implementation: ReadTopic,
        input_schema:
          object_schema(
            {
              topic_id: {
                type: "integer",
                minimum: 1,
              },
              max_posts: {
                type: "integer",
                minimum: 1,
                maximum: 100,
              },
            },
            required: %w[topic_id],
          ),
        output_schema: ReadTopic::OUTPUT_SCHEMA,
        required_scopes: ReadTopic::REQUIRED_SCOPES,
        annotations: READ_ONLY,
      )

      plugin.register_mcp_tool(
        "robot_check_secrets",
        title: "Provjera tajnih podataka",
        description:
          "Provjerava nacrt prije objave: traži lozinke, ključeve i tokene. Vraća vrstu i red nalaza, nikad samu vrijednost.",
        implementation: CheckSecrets,
        input_schema:
          object_schema({ text: { type: "string", minLength: 1, maxLength: 60_000 } }, required: %w[text]),
        output_schema: CheckSecrets::OUTPUT_SCHEMA,
        required_scopes: CheckSecrets::REQUIRED_SCOPES,
        annotations: READ_ONLY,
      )

      plugin.register_mcp_tool(
        "robot_wiki_create_topic",
        title: "Nova tema u IT-Wiki",
        description:
          "Objavljuje novu temu u IT-Wiki kao prijavljeni korisnik. Pozovi tek kad korisnik potvrdi nacrt. " \
            "Tekst sa lozinkama, ključevima ili tokenima biće odbijen.",
        implementation: CreateWikiTopic,
        input_schema:
          object_schema(
            {
              title: {
                type: "string",
                minLength: 5,
                maxLength: 255,
              },
              raw: {
                type: "string",
                minLength: 20,
                maxLength: 30_000,
              },
              tags: {
                type: "array",
                items: {
                  type: "string",
                },
                maxItems: 5,
              },
            },
            required: %w[title raw],
          ),
        output_schema: CreateWikiTopic::OUTPUT_SCHEMA,
        required_scopes: CreateWikiTopic::REQUIRED_SCOPES,
        annotations: WRITE,
        risk: :write,
      )

      plugin.register_mcp_tool(
        "robot_wiki_reply",
        title: "Dopuna teme u IT-Wiki",
        description:
          "Dodaje odgovor (dopunu dokumentacije) u postojeću temu u IT-Wiki kao prijavljeni korisnik. " \
            "Pozovi tek kad korisnik potvrdi nacrt. Tekst sa lozinkama, ključevima ili tokenima biće odbijen.",
        implementation: WikiReply,
        input_schema:
          object_schema(
            {
              topic_id: {
                type: "integer",
                minimum: 1,
              },
              raw: {
                type: "string",
                minLength: 20,
                maxLength: 30_000,
              },
            },
            required: %w[topic_id raw],
          ),
        output_schema: WikiReply::OUTPUT_SCHEMA,
        required_scopes: WikiReply::REQUIRED_SCOPES,
        annotations: WRITE,
        risk: :write,
      )

      plugin.register_mcp_prompt(
        "robot.dokumentuj",
        title: "Dokumentuj u IT-Wiki",
        description: "Upute za pisanje dokumentacije o urađenom poslu u IT-Wiki, bez lozinki.",
        implementation: DocumentPrompt,
        input_schema:
          object_schema({ opis: { type: "string", maxLength: 1000 } }),
        required_scopes: DocumentPrompt::REQUIRED_SCOPES,
        annotations: READ_ONLY,
      )
    end

    def object_schema(properties, required: [])
      { type: "object", properties: properties, required: required, additionalProperties: false }
    end

    def wiki_category_id
      SiteSetting.robot_mcp_wiki_category_id.to_i
    end

    def read_category_ids
      SiteSetting.robot_mcp_read_categories.to_s.split("|").map(&:to_i).push(wiki_category_id).uniq -
        [0]
    end

    def ensure_member!(request_context)
      user = request_context.user
      if user.blank? || !user.in_any_groups?(SiteSetting.robot_mcp_allowed_groups_map)
        raise DiscourseMcp::ToolError, "Ovaj alat je dostupan samo članovima IT tima."
      end
      user
    end

    def find_topic!(topic_id, request_context, category_ids)
      topic = ::Topic.find_by(id: topic_id)
      if topic.blank? || topic.private_message? || !category_ids.include?(topic.category_id) ||
           !request_context.guardian.can_see?(topic)
        raise DiscourseMcp::ToolError,
              "Tema nije pronađena ili nije u dozvoljenoj kategoriji."
      end
      topic
    end

    def create_post!(user, **attributes)
      creator = PostCreator.new(user, **attributes)
      post = creator.create
      if creator.errors.present? || post.blank? || !post.persisted?
        raise DiscourseMcp::ToolError, creator.errors.full_messages.join(", ").presence || "Objava nije uspjela."
      end
      post
    end

    def result(value)
      DiscourseMcp::ToolHelpers.text_and_structured(value)
    end

    module Search
      REQUIRED_SCOPES = [DiscourseMcp::Scopes::CONTENT_READ].freeze
      OUTPUT_SCHEMA =
        DiscourseMcp::OutputSchema.object(results: DiscourseMcp::OutputSchema::OBJECT_ARRAY)

      def self.call(arguments:, request_context:)
        Tools.ensure_member!(request_context)
        category_ids = Tools.read_category_ids
        limit = arguments.fetch("max_results", 10).to_i
        query = "#{arguments.fetch("query")} categories:#{category_ids.map { |id| "=#{id}" }.join(",")}"
        results =
          ::Search.execute(
            query,
            guardian: request_context.guardian,
            type_filter: "topic",
            search_type: :full_page,
            exclude_private_messages: true,
          )
        posts =
          results
            .posts
            .select { |post| category_ids.include?(post.topic&.category_id) }
            .uniq(&:topic_id)
            .first(limit)
        Tools.result(
          results:
            posts.map do |post|
              {
                topic_id: post.topic_id,
                post_number: post.post_number,
                title: post.topic.title,
                category: post.topic.category&.name,
                url: post.full_url,
                excerpt: PrettyText.excerpt(post.cooked, 300, strip_links: true),
              }
            end,
        )
      end
    end

    module ReadTopic
      REQUIRED_SCOPES = [DiscourseMcp::Scopes::CONTENT_READ].freeze
      OUTPUT_SCHEMA =
        DiscourseMcp::OutputSchema.object(
          topic: DiscourseMcp::OutputSchema::OBJECT,
          posts: DiscourseMcp::OutputSchema::OBJECT_ARRAY,
          truncated: DiscourseMcp::OutputSchema::BOOLEAN,
        )

      def self.call(arguments:, request_context:)
        Tools.ensure_member!(request_context)
        topic = Tools.find_topic!(arguments.fetch("topic_id"), request_context, Tools.read_category_ids)
        posts =
          topic
            .posts
            .secured(request_context.guardian)
            .where(deleted_at: nil)
            .order(:post_number)
            .limit(arguments.fetch("max_posts", 50).to_i)
        length = 0
        truncated = false
        rows =
          posts.filter_map do |post|
            next if truncated
            length += post.raw.length
            if length > MAX_READ_LENGTH
              truncated = true
              next
            end
            {
              post_number: post.post_number,
              username: post.username,
              created_at: post.created_at.iso8601,
              raw: post.raw,
            }
          end
        Tools.result(
          topic: {
            id: topic.id,
            title: topic.title,
            category: topic.category&.name,
            url: topic.url,
            posts_count: topic.posts_count,
          },
          posts: rows,
          truncated: truncated,
        )
      end
    end

    module CheckSecrets
      REQUIRED_SCOPES = [DiscourseMcp::Scopes::CONTENT_READ].freeze
      OUTPUT_SCHEMA =
        DiscourseMcp::OutputSchema.object(
          clean: DiscourseMcp::OutputSchema::BOOLEAN,
          findings: DiscourseMcp::OutputSchema::OBJECT_ARRAY,
        )

      def self.call(arguments:, request_context:)
        Tools.ensure_member!(request_context)
        findings = SecretScanner.scan(arguments.fetch("text"))
        Tools.result(clean: findings.empty?, findings: findings)
      end
    end

    module CreateWikiTopic
      REQUIRED_SCOPES = [DiscourseMcp::Scopes::CONTENT_WRITE].freeze
      OUTPUT_SCHEMA =
        DiscourseMcp::OutputSchema.object(
          topic_id: DiscourseMcp::OutputSchema::INTEGER,
          title: DiscourseMcp::OutputSchema::STRING,
          url: DiscourseMcp::OutputSchema::STRING,
          username: DiscourseMcp::OutputSchema::STRING,
        )

      def self.call(arguments:, request_context:)
        user = Tools.ensure_member!(request_context)
        if Tools.wiki_category_id.zero?
          raise DiscourseMcp::ToolError, "Kategorija za IT-Wiki nije podešena."
        end
        SecretScanner.ensure_clean!(arguments.fetch("title"), arguments.fetch("raw"))
        post =
          Tools.create_post!(
            user,
            title: arguments.fetch("title"),
            raw: arguments.fetch("raw"),
            category: Tools.wiki_category_id,
            tags: Array(arguments["tags"]),
          )
        Tools.result(
          topic_id: post.topic_id,
          title: post.topic.title,
          url: post.topic.url,
          username: post.user.username,
        )
      end
    end

    module WikiReply
      REQUIRED_SCOPES = [DiscourseMcp::Scopes::CONTENT_WRITE].freeze
      OUTPUT_SCHEMA =
        DiscourseMcp::OutputSchema.object(
          topic_id: DiscourseMcp::OutputSchema::INTEGER,
          post_number: DiscourseMcp::OutputSchema::INTEGER,
          url: DiscourseMcp::OutputSchema::STRING,
          username: DiscourseMcp::OutputSchema::STRING,
        )

      def self.call(arguments:, request_context:)
        user = Tools.ensure_member!(request_context)
        topic = Tools.find_topic!(arguments.fetch("topic_id"), request_context, [Tools.wiki_category_id])
        SecretScanner.ensure_clean!(arguments.fetch("raw"))
        post = Tools.create_post!(user, topic_id: topic.id, raw: arguments.fetch("raw"))
        Tools.result(
          topic_id: post.topic_id,
          post_number: post.post_number,
          url: post.full_url,
          username: post.user.username,
        )
      end
    end

    module DocumentPrompt
      REQUIRED_SCOPES = [DiscourseMcp::Scopes::CONTENT_READ].freeze

      def self.call(arguments:, request_context:)
        Tools.ensure_member!(request_context)
        text = DOCUMENT_INSTRUCTIONS
        text += "\nŠta treba dokumentovati: #{arguments["opis"]}\n" if arguments["opis"].present?
        {
          description: "Dokumentuj u IT-Wiki",
          messages: [{ role: "user", content: { type: "text", text: text } }],
        }
      end
    end
  end
end
