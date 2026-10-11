"""Auditioner audition-feed crawler.

Reads orchestras' *own* public audition pages (never aggregators), notices when a
page or a linked repertoire list changes, asks Claude to extract the list into a
fixed JSON shape, checks every extracted item against the cited source lines in
plain code, maps items to the excerpt catalogue, and hands the result to a review
queue (Supabase) or to local JSON files (dry run). The rules the bot follows are
public in docs/BOT.md; the pipeline is described in docs/FEED.md.
"""

__version__ = "0.1.0"

USER_AGENT = (
    "AuditionerBot/0.1 "
    "(+https://github.com/milaiwalkerproject-ui/auditioner/blob/main/docs/BOT.md)"
)
ROBOTS_AGENT_TOKEN = "AuditionerBot"
