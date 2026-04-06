# OpenCode Controller Architecture

## Objective
- determine whether an OpenCode session is busy
- submit a message or command only when the session is safe to accept it
- expose a small control surface that other local automation can call

## Initial control contract
- `status`
  - returns one of: `busy`, `idle`, `waiting_user`, `unknown`
- `send`
  - sends a prompt or command to a chosen OpenCode session
- `wait`
  - blocks until session reaches `idle` or timeout

## Preferred truth sources
1. OpenCode session/status APIs or event stream
2. OpenCode server-side session metadata
3. terminal/tmux fallback only if native state is unavailable

## Non-goals for the first pass
- no scheduler yet
- no Telegram/Discord delivery yet
- no broad multi-agent orchestration yet
- no heavy UI yet

## Minimal layout
- `src/client.ts` - OpenCode API wrapper
- `src/status.ts` - state resolution
- `src/send.ts` - prompt/command submission
- `src/wait.ts` - wait-until-idle helper
- `src/index.ts` - thin entrypoint
