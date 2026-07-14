defmodule Acs.Accounts.UserToken do
  use Ecto.Schema
  import Ecto.Query
  alias Acs.Accounts.UserToken

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
     %UserToken{
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

  def verify_session_token_query(token, org \\ Acs.Org.current()) do
    verify_token_query(token, "session", session_validity_days(), :day, org)
  end

  defp verify_token_query(token, context, validity, unit, org) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(@hash_algorithm, decoded_token)
        cutoff = DateTime.add(DateTime.utc_now(), -validity, unit)

        query =
          from token in token_and_context_query(hashed_token, context),
            join: user in assoc(token, :user),
            where: token.inserted_at > ^cutoff,
            where: token.org == ^org and user.org == ^org,
            select: user

        {:ok, query}

      :error ->
        :error
    end
  end

  defp token_and_context_query(token, context) do
    from UserToken, where: [token: ^token, context: ^context]
  end
end
