defmodule AshAuthentication.Dsl do
  @moduledoc false

  ###
  ### Only exists to move the DSL out of `AshAuthentication` to aid readability.
  ###

  import AshAuthentication.Utils, only: [to_sentence: 2]
  import Joken.Signer, only: [algorithms: 0]

  alias Ash.{Api, Resource}

  alias AshAuthentication.{
    AddOn.Confirmation,
    Strategy.OAuth2,
    Strategy.Password
  }

  alias Spark.{
    Dsl.Entity,
    Dsl.Section,
    OptionsHelpers
  }

  @shared_strategy_options [
    name: [
      type: :atom,
      doc: """
      Uniquely identifies the strategy.
      """,
      required: true
    ]
  ]

  @shared_addon_options [
    name: [
      type: :atom,
      doc: """
      Uniquely identifies the add-on.
      """,
      required: true
    ]
  ]

  @default_token_lifetime_days 14
  @default_confirmation_lifetime_days 3

  @secret_type {:or,
                [
                  {:spark_function_behaviour, AshAuthentication.Secret,
                   {AshAuthentication.SecretFunction, 2}},
                  :string
                ]}

  @secret_doc """
  Takes either a module which implements the `AshAuthentication.Secret`
  behaviour, a 2 arity anonymous function or a string.

  See the module documentation for `AshAuthentication.Secret` for more
  information.
  """

  @doc false
  @spec dsl :: [Section.t()]
  def dsl do
    [
      %Section{
        name: :authentication,
        describe: "Configure authentication for this resource",
        modules: [:api],
        schema: [
          subject_name: [
            type: :atom,
            doc: """
            The subject name is used anywhere that a short version of your
            resource name is needed, eg:

              - generating token claims,
              - generating routes,
              - form parameter nesting.

            This needs to be unique system-wide and if not set will be inferred
            from the resource name (ie `MyApp.Accounts.User` will have a subject
            name of `user`).
            """
          ],
          api: [
            type: {:behaviour, Api},
            doc: """
            The name of the Ash API to use to access this resource when
            doing anything authenticaiton related.
            """,
            required: true
          ],
          get_by_subject_action_name: [
            type: :atom,
            doc: """
            The name of the read action used to retrieve records.

            Used internally by `AshAuthentication.subject_to_user/2`.  If the
            action doesn't exist, one will be generated for you.
            """,
            default: :get_by_subject
          ]
        ],
        sections: [
          %Section{
            name: :tokens,
            describe: "Configure JWT settings for this resource",
            modules: [:token_resource],
            schema: [
              enabled?: [
                type: :boolean,
                doc: """
                Should JWTs be generated by this resource?
                """,
                default: false
              ],
              signing_algorithm: [
                type: :string,
                doc: """
                The algorithm to use for token signing.

                Available signing algorithms are;
                #{to_sentence(algorithms(), final: "and")}.
                """,
                default: hd(algorithms())
              ],
              token_lifetime: [
                type: :pos_integer,
                doc: """
                How long a token should be valid, in hours.

                Since refresh tokens are not yet supported, you should
                probably set this to a reasonably long time to ensure
                a good user experience.

                Defaults to #{@default_token_lifetime_days} days.
                """,
                default: @default_token_lifetime_days * 24
              ],
              token_resource: [
                type: {:or, [{:behaviour, Resource}, {:in, [false]}]},
                doc: """
                The resource used to store token information.

                If token generation is enabled for this resource, we need a place to
                store information about tokens, such as revocations and in-flight
                confirmations.
                """,
                required: true
              ]
            ]
          },
          %Section{
            name: :strategies,
            describe: "Configure authentication strategies on this resource",
            entities: [
              strategy(:password),
              strategy(:oauth2)
            ]
          },
          %Section{
            name: :add_ons,
            describe: "Additional add-ons related to, but not providing authentication",
            entities: [
              strategy(:confirmation)
            ]
          }
        ]
      }
    ]
  end

  # The result spec should be changed to `Entity.t` when Spark 0.2.18 goes out.
  @doc false
  @spec strategy(:confirmation | :oauth2 | :password) :: map
  def strategy(:password) do
    %Entity{
      name: :password,
      describe: "Strategy for authenticating using local resources as the source of truth.",
      examples: [
        """
        password :password do
          identity_field :email
          hashed_password_field :hashed_password
          hash_provider AshAuthentication.BcryptProvider
          confirmation_required? true
        end
        """
      ],
      args: [:name],
      hide: [:name],
      target: Password,
      modules: [:hash_provider],
      schema:
        OptionsHelpers.merge_schemas(
          [
            identity_field: [
              type: :atom,
              doc: """
              The name of the attribute which uniquely identifies the user.

              Usually something like `username` or `email_address`.
              """,
              default: :username
            ],
            hashed_password_field: [
              type: :atom,
              doc: """
              The name of the attribute within which to store the user's password
              once it has been hashed.
              """,
              default: :hashed_password
            ],
            hash_provider: [
              type: {:behaviour, AshAuthentication.HashProvider},
              doc: """
              A module which implements the `AshAuthentication.HashProvider`
              behaviour.

              Used to provide cryptographic hashing of passwords.
              """,
              default: AshAuthentication.BcryptProvider
            ],
            confirmation_required?: [
              type: :boolean,
              required: false,
              doc: """
              Whether a password confirmation field is required when registering or
              changing passwords.
              """,
              default: true
            ],
            password_field: [
              type: :atom,
              doc: """
              The name of the argument used to collect the user's password in
              plaintext when registering, checking or changing passwords.
              """,
              default: :password
            ],
            password_confirmation_field: [
              type: :atom,
              doc: """
              The name of the argument used to confirm the user's password in
              plaintext when registering or changing passwords.
              """,
              default: :password_confirmation
            ],
            register_action_name: [
              type: :atom,
              doc: """
              The name to use for the register action.

              If not present it will be generated by prepending the strategy name
              with `register_with_`.
              """,
              required: false
            ],
            sign_in_action_name: [
              type: :atom,
              doc: """
              The name to use for the sign in action.

              If not present it will be generated by prependign the strategy name
              with `sign_in_with_`.
              """,
              required: false
            ]
          ],
          @shared_strategy_options,
          "Shared options"
        ),
      entities: [resettable: [Password.Resettable.entity()]]
    }
  end

  def strategy(:oauth2) do
    %Entity{
      name: :oauth2,
      describe: "OAuth2 authentication",
      args: [:name],
      target: OAuth2,
      modules: [
        :authorize_path,
        :client_id,
        :client_secret,
        :identity_resource,
        :private_key,
        :redirect_uri,
        :site,
        :token_path,
        :user_path
      ],
      schema:
        OptionsHelpers.merge_schemas(
          [
            client_id: [
              type: @secret_type,
              doc: """
              The OAuth2 client ID.

              #{@secret_doc}

              Example:

              ```elixir
              client_id fn _, resource ->
                :my_app
                |> Application.get_env(resource, [])
                |> Keyword.fetch(:oauth_client_id)
              end
              ```
              """,
              required: true
            ],
            site: [
              type: @secret_type,
              doc: """
              The base URL of the OAuth2 server - including the leading protocol
              (ie `https://`).

              #{@secret_doc}

              Example:

              ```elixir
              site fn _, resource ->
                :my_app
                |> Application.get_env(resource, [])
                |> Keyword.fetch(:oauth_site)
              end
              ```
              """,
              required: true
            ],
            auth_method: [
              type:
                {:in,
                 [
                   nil,
                   :client_secret_basic,
                   :client_secret_post,
                   :client_secret_jwt,
                   :private_key_jwt
                 ]},
              doc: """
              The authentication strategy used, optional. If not set, no
              authentication will be used during the access token request. The
              value may be one of the following:

              * `:client_secret_basic`
              * `:client_secret_post`
              * `:client_secret_jwt`
              * `:private_key_jwt`
              """,
              default: :client_secret_post
            ],
            client_secret: [
              type: @secret_type,
              doc: """
              The OAuth2 client secret.

              Required if :auth_method is `:client_secret_basic`,
              `:client_secret_post` or `:client_secret_jwt`.

              #{@secret_doc}

              Example:

              ```elixir
              site fn _, resource ->
                :my_app
                |> Application.get_env(resource, [])
                |> Keyword.fetch(:oauth_site)
              end
              ```
              """,
              required: false
            ],
            authorize_path: [
              type: @secret_type,
              doc: """
              The API path to the OAuth2 authorize endpoint.

              Relative to the value of `site`.
              If not set, it defaults to `#{inspect(OAuth2.Default.default(:authorize_path))}`.

              #{@secret_doc}

              Example:

              ```elixir
              authorize_path fn _, _ -> {:ok, "/authorize"} end
              ```
              """,
              required: false
            ],
            token_path: [
              type: @secret_type,
              doc: """
              The API path to access the token endpoint.

              Relative to the value of `site`.
              If not set, it defaults to `#{inspect(OAuth2.Default.default(:token_path))}`.

              #{@secret_doc}

              Example:

              ```elixir
              token_path fn _, _ -> {:ok, "/oauth_token"} end
              ```
              """,
              required: false
            ],
            user_path: [
              type: @secret_type,
              doc: """
              The API path to access the user endpoint.

              Relative to the value of `site`.
              If not set, it defaults to `#{inspect(OAuth2.Default.default(:user_path))}`.

              #{@secret_doc}

              Example:

              ```elixir
              user_path fn _, _ -> {:ok, "/userinfo"} end
              ```
              """,
              required: false
            ],
            private_key: [
              type: @secret_type,
              doc: """
              The private key to use if `:auth_method` is `:private_key_jwt`

              #{@secret_doc}
              """,
              required: false
            ],
            redirect_uri: [
              type: @secret_type,
              doc: """
              The callback URI base.

              Not the whole URI back to the callback endpoint, but the URI to your
              `AuthPlug`.  We can generate the rest.

              Whilst not particularly secret, it seemed prudent to allow this to be
              configured dynamically so that you can use different URIs for
              different environments.

              #{@secret_doc}
              """,
              required: true
            ],
            authorization_params: [
              type: :keyword_list,
              doc: """
              Any additional parameters to encode in the request phase.

              eg: `authorization_params scope: "openid profile email"`
              """,
              default: []
            ],
            registration_enabled?: [
              type: :boolean,
              doc: """
              Is registration enabled for this provider?

              If this option is enabled, then new users will be able to register for
              your site when authenticating and not already present.

              If not, then only existing users will be able to authenticate.
              """,
              default: true
            ],
            register_action_name: [
              type: :atom,
              doc: ~S"""
              The name of the action to use to register a user.

              Only needed if `registration_enabled?` is `true`.

              Because we we don't know the response format of the server, you must
              implement your own registration action of the same name.

              See the "Registration and Sign-in" section of the module
              documentation for more information.

              The default is computed from the strategy name eg:
              `register_with_#{name}`.
              """,
              required: false
            ],
            sign_in_action_name: [
              type: :atom,
              doc: ~S"""
              The name of the action to use to sign in an existing user.

              Only needed if `registration_enabled?` is `false`.

              Because we don't know the response format of the server, you must
              implement your own sign-in action of the same name.

              See the "Registration and Sign-in" section of the module
              documentation for more information.

              The default is computed from the strategy name, eg:
              `sign_in_with_#{name}`.
              """,
              required: false
            ],
            identity_resource: [
              type: {:or, [{:behaviour, Ash.Resource}, {:in, [false]}]},
              doc: """
              The resource used to store user identities.

              Given that a user can be signed into multiple different
              authentication providers at once we use the
              `AshAuthentication.UserIdentity` resource to build a mapping
              between users, providers and that provider's uid.

              See the Identities section of the module documentation for more
              information.

              Set to `false` to disable.
              """,
              default: false
            ],
            identity_relationship_name: [
              type: :atom,
              doc: "Name of the relationship to the provider identities resource",
              default: :identities
            ],
            identity_relationship_user_id_attribute: [
              type: :atom,
              doc: """
              The name of the destination (user_id) attribute on your provider
              identity resource.

              The only reason to change this would be if you changed the
              `user_id_attribute_name` option of the provider identity.
              """,
              default: :user_id
            ]
          ],
          @shared_strategy_options,
          "Shared options"
        )
    }
  end

  def strategy(:confirmation) do
    %Entity{
      name: :confirmation,
      describe: "User confirmation flow",
      args: [:name],
      target: Confirmation,
      modules: [:sender],
      schema:
        OptionsHelpers.merge_schemas(
          [
            token_lifetime: [
              type: :pos_integer,
              doc: """
              How long should the confirmation token be valid, in hours.

              Defaults to #{@default_confirmation_lifetime_days} days.
              """,
              default: @default_confirmation_lifetime_days * 24
            ],
            monitor_fields: [
              type: {:list, :atom},
              doc: """
              A list of fields to monitor for changes (eg `[:email, :phone_number]`).

              The confirmation will only be sent when one of these fields are changed.
              """,
              required: true
            ],
            confirmed_at_field: [
              type: :atom,
              doc: """
              The name of a field to store the time that the last confirmation took
              place.

              This attribute will be dynamically added to the resource if not already
              present.
              """,
              default: :confirmed_at
            ],
            confirm_on_create?: [
              type: :boolean,
              doc: """
              Generate and send a confirmation token when a new resource is created?

              Will only trigger when a create action is executed _and_ one of the
              monitored fields is being set.
              """,
              default: true
            ],
            confirm_on_update?: [
              type: :boolean,
              doc: """
              Generate and send a confirmation token when a resource is changed?

              Will only trigger when an update action is executed _and_ one of the
              monitored fields is being set.
              """,
              default: true
            ],
            inhibit_updates?: [
              type: :boolean,
              doc: """
              Wait until confirmation is received before actually changing a monitored
              field?

              If a change to a monitored field is detected, then the change is stored
              in the token resource and  the changeset updated to not make the
              requested change.  When the token is confirmed, the change will be
              applied.

              This could be potentially weird for your users, but useful in the case
              of a user changing their email address or phone number where you want
              to verify that the new contact details are reachable.
              """,
              default: true
            ],
            sender: [
              type:
                {:spark_function_behaviour, AshAuthentication.Sender,
                 {AshAuthentication.SenderFunction, 2}},
              doc: """
              How to send the confirmation instructions to the user.

              Allows you to glue sending of confirmation instructions to
              [swoosh](https://hex.pm/packages/swoosh),
              [ex_twilio](https://hex.pm/packages/ex_twilio) or whatever notification
              system is appropriate for your application.

              Accepts a module, module and opts, or a function that takes a record,
              reset token and options.

              See `AshAuthentication.Sender` for more information.
              """,
              required: true
            ],
            confirm_action_name: [
              type: :atom,
              doc: """
              The name of the action to use when performing confirmation.

              If this action is not already present on the resource, it will be
              created for you.
              """,
              default: :confirm
            ]
          ],
          @shared_addon_options,
          "Shared options"
        )
    }
  end
end
