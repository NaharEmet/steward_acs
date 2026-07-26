defmodule Acs.Accounts.UserToken do
  use Ecto.Schema
  import Ecto.Query

  @hash_algorithm :sha256
  @rand_size 32

  schema "users_tokens" do
    field :token, :binary
    field :context, :string
    field :sent_to, :string
    field :org, :string, default: "default"
    belongs_to :user, Acs.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def build_session_token(user) do
    token = :crypto.strong_rand_bytes(@rand_size)
    hashed_token = :crypto.hash(@hash_algorithm, token)

    {Base.url_encode64(token, padding: false),
     %__MODULE__{
       token: hashed_token,
       context: "session",
       sent_to: user.email,
       user_id: user.id,
       org: user.org
     }}
  end

  def session_validity_days do
    Application.get_env(:steward_acs, :session_validity_in_days, 7)
  end

  def verify_session_token_query(token, _org \\ nil) do
    verify_token_query(token, "session", session_validity_days(), :day)
  end

  defp verify_token_query(token, context, validity, unit) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(@hash_algorithm, decoded_token)
        cutoff = DateTime.add(DateTime.utc_now(), -validity, unit)

        query =
          from user in Acs.Accounts.User,
            join: token in __MODULE__,
            on: token.user_id == user.id,
            left_join: organization in assoc(user, :organization),
            where:
              token.token == ^hashed_token and token.context == ^context and
                token.inserted_at > ^cutoff,
            preload: [organization: organization]

        {:ok, query}

      :error ->
        :error
    end
  end
end
