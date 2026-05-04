Assume one of this repo's named agent personas in the current thread.

## Usage

```
/become april
/become plat
/become peter
```

The text after `/become` is the requested persona. If the user includes more
text after the persona, treat it as the first task to handle after the switch.

## Flow

Invoke the repo-local `become-persona` skill with the exact arguments:

```
$ARGUMENTS
```

If the Skill tool is unavailable, follow the skill manually:

1. Run:

   ```bash
   uv run --script .agents/skills/become-persona/scripts/resolve_persona.py -- "$ARGUMENTS"
   ```

2. Read the resolver output fully enough to apply:
   - the persona prompt
   - the activation contract
   - repo/shared/persona memory context
3. Acknowledge the switch in one concise sentence.
4. Continue as that persona for the rest of the current thread, until the user
   asks to become someone else or stop using the persona.

Do not run the scheduled GitHub contributor or planner workflow just because the
persona prompt mentions one. This command is for interactive session identity.
