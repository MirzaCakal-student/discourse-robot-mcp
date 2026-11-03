# discourse-robot-mcp

Dodatak za Discourse koji ugrađenom Discourse MCP serveru dodaje alate za IT tim:
Claude (claude.ai, desktop, Claude Code) piše dokumentaciju o urađenom poslu i objavljuje je u IT-Wiki
pod imenom prijavljenog korisnika, bez lozinki.

## Alati

| Alat | Šta radi |
|---|---|
| `robot_search` | Pretraga IT-Wiki i dozvoljenih IT kategorija |
| `robot_read_topic` | Čitanje teme iz dozvoljenih kategorija |
| `robot_check_secrets` | Provjera nacrta na lozinke, ključeve i tokene |
| `robot_wiki_create_topic` | Nova tema u IT-Wiki (odbija tekst sa tajnama) |
| `robot_wiki_reply` | Dopuna postojeće teme u IT-Wiki (odbija tekst sa tajnama) |
| prompt `robot.dokumentuj` | Obrazac i pravila za dokumentaciju |

Pisanje je moguće samo u kategoriju iz `robot_mcp_wiki_category_id`, a čitanje samo iz nje i iz
`robot_mcp_read_categories` (tačne kategorije, bez potkategorija). Alate mogu koristiti samo članovi
grupa iz `robot_mcp_allowed_groups`.

## Postavljanje

1. Instaliraj plugin (u `app.yml`: `git clone https://github.com/adopilot/discourse-robot-mcp.git`).
2. Uključi `mcp_server_enabled` i `robot_mcp_enabled`, podesi kategorije i grupe.
3. U Admin → MCP uključi `robot_*` alate i prompt, a grupi IT tima daj dozvole `mcp:content:read` i `mcp:content:write`.
4. U Claudeu dodaj konektor `https://<forum>/mcp`. Svaki korisnik se jednom prijavi svojim forumskim nalogom.
