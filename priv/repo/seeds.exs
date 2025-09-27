alias Fleetlm.Repo

participants = [
  {"user:demo", "user", "Demo User"},
  {"agent:echo", "agent", "Echo Agent"}
]

Enum.each(participants, fn {id, kind, display_name} ->
  Repo.query!(
    """
    INSERT INTO participants (id, kind, display_name, status, metadata, inserted_at, updated_at)
    VALUES ($1, $2, $3, 'active', '{}'::jsonb, NOW(), NOW())
    ON CONFLICT (id) DO UPDATE SET
      kind = EXCLUDED.kind,
      display_name = EXCLUDED.display_name,
      status = EXCLUDED.status,
      updated_at = NOW()
    """,
    [id, kind, display_name]
  )
end)
