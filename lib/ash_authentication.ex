defmodule AshAuthentication do
  import AshAuthentication.Dsl

  @moduledoc """
  AshAuthentication provides a turn-key authentication solution for folks using
  [Ash](https://www.ash-hq.org/).

  ## Usage

  This package assumes that you have [Ash](https://ash-hq.org/) installed and
  configured.  See the Ash documentation for details.

  Once installed you can easily add support for authentication by configuring
  the `AshAuthentication` extension on your resource:

  ```elixir
  defmodule MyApp.Accounts.User do
    use Ash.Resource,
      extensions: [AshAuthentication]

    attributes do
      uuid_primary_key :id
      attribute :email, :ci_string, allow_nil?: false
      attribute :hashed_password, :string, allow_nil?: false, sensitive?: true
    end

    authentication do
      api MyApp.Accounts

      strategies do
        password do
          identity_field :email
          hashed_password_field :hashed_password
        end
      end
    end

    identities do
      identity :unique_email, [:email]
    end
  end
  ```

  If you plan on providing authentication via the web, then you will need to
  define a plug using `AshAuthentication.Plug` which builds a `Plug.Router` that
  routes incoming authentication requests to the correct provider and provides
  callbacks for you to manipulate the conn after success or failure.

  If you're using AshAuthentication with Phoenix, then check out
  [`ash_authentication_phoenix`](https://github.com/team-alembic/ash_authentication_phoenix)
  which provides route helpers, a controller abstraction and LiveView components
  for easy set up.

  ## Authentication Strategies

  Currently supported strategies:

  1. {{link:ash_authentication:module:AshAuthentication.Strategy.Password}}
     - authenticate users against your local database using a unique identity
     (such as username or email address) and a password.
  2. {{link:ash_authentication:module:AshAuthentication.Strategy.OAuth2}}
     - authenticate using local or remote [OAuth 2.0](https://oauth.net/2/)
     compatible services.

  ## Add-ons

  Add-ons are like strategies, except that they don't actually provide
  authentication - they just provide features adjacent to authentication.
  Current add-ons:

  1. {{link:ash_authentication:module:AshAuthentication.AddOn.Confirmation}}
     - allows you to force the user to confirm changes using a confirmation
       token (eg. sending a confirmation email when a new user registers).

  ## Supervisor

  Some add-ons or strategies may require processes to be started which manage
  their state over the lifetime of the application (eg periodically deleting
  expired token revocations).  Because of this you should add
  `{AshAuthentication.Supervisor, otp_app: :my_app}` to your application's
  supervision tree.  See [the Elixir
  docs](https://hexdocs.pm/elixir/Application.html#module-the-application-callback-module)
  for more information.

  ## DSL Documentation

  ### Index

  #{Spark.Dsl.Extension.doc_index(dsl())}

  ### Docs

  #{Spark.Dsl.Extension.doc(dsl())}

  """
  alias Ash.{Api, Error.Query.NotFound, Query, Resource}
  alias AshAuthentication.Info
  alias Spark.Dsl.Extension

  use Spark.Dsl.Extension,
    sections: dsl(),
    transformers: [
      AshAuthentication.Transformer,
      AshAuthentication.Verifier,
      AshAuthentication.Strategy.Password.Transformer,
      AshAuthentication.Strategy.Password.Verifier,
      AshAuthentication.Strategy.OAuth2.Transformer,
      AshAuthentication.Strategy.OAuth2.Verifier,
      AshAuthentication.AddOn.Confirmation.Transformer,
      AshAuthentication.AddOn.Confirmation.Verifier
    ]

  require Ash.Query

  @type resource_config :: %{
          api: module,
          providers: [module],
          resource: module,
          subject_name: atom
        }

  @type subject :: String.t()

  @doc """
  Find all resources which support authentication for a given OTP application.

  Returns a list of resource modules.

  ## Example

      iex> authenticated_resources(:ash_authentication)
      [Example.User]

  """
  @spec authenticated_resources(atom) :: [Resource.t()]
  def authenticated_resources(otp_app) do
    otp_app
    |> Application.get_env(:ash_apis, [])
    |> Stream.flat_map(&Api.Info.resources(&1))
    |> Stream.filter(&(AshAuthentication in Spark.extensions(&1)))
    |> Enum.to_list()
  end

  @doc """
  Return a subject string for user.

  This is done by concatenating the resource's subject name with the resource's
  primary key field(s) to generate a uri-like string.

  Example:

      iex> build_user(id: "ce7969f9-afa5-474c-bc52-ac23a103cef6") |> user_to_subject()
      "user?id=ce7969f9-afa5-474c-bc52-ac23a103cef6"

  """
  @spec user_to_subject(Resource.record()) :: subject
  def user_to_subject(record) do
    subject_name =
      record.__struct__
      |> Info.authentication_subject_name!()

    record.__struct__
    |> Resource.Info.primary_key()
    |> then(&Map.take(record, &1))
    |> then(fn primary_key ->
      "#{subject_name}?#{URI.encode_query(primary_key)}"
    end)
  end

  @doc ~S"""
  Given a subject string, attempt to retrieve a user record.

      iex> %{id: user_id} = build_user()
      ...> {:ok, %{id: ^user_id}} = subject_to_user("user?id=#{user_id}", Example.User)

  Any options passed will be passed to the underlying `Api.read/2` callback.
  """
  @spec subject_to_user(subject | URI.t(), Resource.t(), keyword) ::
          {:ok, Resource.record()} | {:error, any}

  def subject_to_user(subject, resource, options \\ [])

  def subject_to_user(subject, resource, options) when is_binary(subject),
    do: subject |> URI.parse() |> subject_to_user(resource, options)

  def subject_to_user(%URI{path: subject_name, query: primary_key} = _subject, resource, options) do
    with {:ok, resource_subject_name} <- Info.authentication_subject_name(resource),
         ^subject_name <- to_string(resource_subject_name),
         {:ok, action_name} <- Info.authentication_get_by_subject_action_name(resource),
         {:ok, api} <- Info.authentication_api(resource) do
      primary_key =
        primary_key
        |> URI.decode_query()
        |> Enum.to_list()

      resource
      |> Query.for_read(action_name, %{})
      |> Query.filter(^primary_key)
      |> api.read(options)
      |> case do
        {:ok, [user]} -> {:ok, user}
        _ -> {:error, NotFound.exception([])}
      end
    end
  end
end
