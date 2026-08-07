defmodule Isthmus.Announce.Dedup do
  @moduledoc "Persistent TTL dedup keys for announce/advert suppression."

  import Ecto.Query
  alias Isthmus.Repo

  defmodule Entry do
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key {:id, :binary_id, autogenerate: true}
    schema "dedup_entries" do
      field :dedup_key, :string
      field :expires_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    def changeset(e, attrs) do
      e
      |> cast(attrs, [:dedup_key, :expires_at])
      |> validate_required([:dedup_key, :expires_at])
      |> unique_constraint(:dedup_key)
    end
  end

  def seen?(key, ttl_sec) when is_binary(key) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    purge_expired(now)

    case Repo.get_by(Entry, dedup_key: key) do
      %Entry{expires_at: exp} when exp > now ->
        true

      _ ->
        expires = DateTime.add(now, ttl_sec, :second)

        %Entry{}
        |> Entry.changeset(%{dedup_key: key, expires_at: expires})
        |> Repo.insert(
          on_conflict: {:replace, [:expires_at, :updated_at]},
          conflict_target: [:dedup_key]
        )

        false
    end
  end

  defp purge_expired(now) do
    Entry
    |> where([e], e.expires_at <= ^now)
    |> Repo.delete_all()
  end
end
