defmodule Acs.Accounts do
  @moduledoc """
  Accounts context for dashboard authentication.
  """
  import Ecto.Query, warn: false
  alias Acs.Repo
  alias Acs.Accounts.{User, UserToken}

  def get_user_by_email(email, org \\ Acs.Org.current()) when is_binary(email) do
    Repo.get_by(User, email: email, org: org)
  end

  def get_user!(id), do: Repo.get!(User, id)

  def register_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  def get_or_register_user(email, org \\ Acs.Org.current()) do
    case get_user_by_email(email, org) do
      %User{} = user -> {:ok, user}
      nil -> register_user(%{email: email, org: org})
    end
  end

  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  def get_user_by_session_token(token) do
    case UserToken.verify_session_token_query(token) do
      {:ok, query} -> Repo.one(query)
      :error -> nil
    end
  end

  def get_user_by_session_token(token, org) when is_binary(org) do
    case UserToken.verify_session_token_query(token, org) do
      {:ok, query} -> Repo.one(query)
      :error -> nil
    end
  end

  def delete_user_session_token(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded} ->
        hashed = :crypto.hash(:sha256, decoded)
        Repo.delete_all(from t in UserToken, where: t.token == ^hashed and t.context == "session")
        :ok

      :error ->
        :ok
    end
  end
end
