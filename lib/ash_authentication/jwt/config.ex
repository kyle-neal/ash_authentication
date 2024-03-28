defmodule AshAuthentication.Jwt.Config do
  @moduledoc """
  Implementation details JWT generation and validation.

  Provides functions to generate token configuration at runtime, based on the
  resource being signed for and for verifying claims and checking for token
  revocation.
  """

  alias Ash.Resource
  alias AshAuthentication.{Info, Jwt, TokenResource}
  alias Joken.{Config, Signer}

  @doc """
  Generate the default claims for a specified resource.
  """
  @spec default_claims(Resource.t(), keyword) :: Joken.token_config()
  def default_claims(resource, opts \\ []) do
    token_lifetime =
      opts
      |> Keyword.fetch(:token_lifetime)
      |> case do
        {:ok, lifetime} -> lifetime_to_seconds(lifetime)
        :error -> token_lifetime(resource)
      end

    {:ok, vsn} = :application.get_key(:ash_authentication, :vsn)

    vsn =
      vsn
      |> to_string()
      |> Version.parse!()
      |> then(&%{&1 | pre: []})

    Config.default_claims(default_exp: token_lifetime)
    |> Config.add_claim(
      "iss",
      fn -> generate_issuer(vsn) end,
      &validate_issuer/3
    )
    |> Config.add_claim(
      "aud",
      fn -> generate_audience(vsn) end,
      &validate_audience(&1, &2, &3, vsn)
    )
    |> Config.add_claim(
      "jti",
      &Joken.generate_jti/0,
      &validate_jti(&1, &2, &3, opts)
    )
  end

  @doc """
  The generator function used to generate the "iss" claim.
  """
  @spec generate_issuer(Version.t()) :: String.t()
  def generate_issuer(vsn) do
    "AshAuthentication v#{vsn}"
  end

  @doc """
  The validation function used to validate the "iss" claim.

  It simply verifies that the claim starts with `"AshAuthentication"`
  """
  @spec validate_issuer(String.t(), any, any) :: boolean
  def validate_issuer(claim, _, _), do: String.starts_with?(claim, "AshAuthentication")

  @doc """
  The generator function used to generate the "aud" claim.

  It generates an Elixir-style `~>` version requirement against the current
  major and minor version numbers of AshAuthentication.
  """
  @spec generate_audience(Version.t()) :: String.t()
  def generate_audience(vsn) do
    "~> #{vsn.major}.#{vsn.minor}"
  end

  @doc """
  The validation function used to validate the "aud" claim.

  Uses `Version.match?/2` to validate the provided claim against the current
  version.  The use of `~>` means that tokens generated by versions of
  AshAuthentication with the the same major version and at least the same minor
  version should be compatible.
  """
  @spec validate_audience(String.t(), any, any, Version.t()) :: boolean
  def validate_audience(claim, _, _, vsn) do
    Version.match?(vsn, Version.parse_requirement!(claim))
  end

  @doc """
  The validation function used to the validate the "jti" claim.

  This is done by checking that the token is valid with the token revocation
  resource.  Requires that the subject's resource configuration be passed as the
  validation context.  This is automatically done by calling `Jwt.verify/2`.
  """
  @spec validate_jti(String.t(), any, Resource.t() | any, Keyword.t()) :: boolean
  def validate_jti(jti, _claims, resource, opts \\ [])

  def validate_jti(jti, _claims, resource, opts) when is_atom(resource) do
    case Info.authentication_tokens_token_resource(resource) do
      {:ok, token_resource} ->
        TokenResource.Actions.valid_jti?(token_resource, jti, opts)

      _ ->
        false
    end
  end

  def validate_jti(_, _, _, _), do: false

  @doc """
  The signer used to sign the token on a per-resource basis.
  """
  @spec token_signer(Resource.t(), keyword) :: Signer.t()
  def token_signer(resource, opts \\ []) do
    algorithm =
      with :error <- Keyword.fetch(opts, :signing_algorithm),
           :error <- Info.authentication_tokens_signing_algorithm(resource) do
        Jwt.default_algorithm()
      else
        {:ok, algorithm} -> algorithm
      end

    signing_secret =
      with :error <- Keyword.fetch(opts, :signing_secret),
           {:ok, {secret_module, secret_opts}} <-
             Info.authentication_tokens_signing_secret(resource),
           {:ok, secret} when is_binary(secret) <-
             secret_module.secret_for(
               ~w[authentication tokens signing_secret]a,
               resource,
               secret_opts
             ) do
        secret
      else
        {:ok, secret} when is_binary(secret) ->
          secret

        {:ok, secret} when not is_binary(secret) ->
          raise "Invalid JWT signing secret: #{inspect(secret)}. Please see the documentation for `AshAuthentication.Jwt` for details"

        secret when is_binary(secret) ->
          raise "Invalid JWT signing secret format: Make sure to return a success tuple like `{:ok, \"signing_secret\"}`." <>
                  " Please see the documentation for `AshAuthentication.Jwt` for details"

        _ ->
          raise "Missing JWT signing secret. Please see the documentation for `AshAuthentication.Jwt` for details"
      end

    Signer.create(algorithm, signing_secret)
  end

  defp token_lifetime(resource) do
    resource
    |> Info.authentication_tokens_token_lifetime()
    |> case do
      {:ok, lifetime} -> lifetime_to_seconds(lifetime)
      :error -> Jwt.default_lifetime_hrs() * 60 * 60
    end
  end

  defp lifetime_to_seconds({seconds, :seconds}), do: seconds
  defp lifetime_to_seconds({minutes, :minutes}), do: minutes * 60
  defp lifetime_to_seconds({hours, :hours}), do: hours * 60 * 60
  defp lifetime_to_seconds({days, :days}), do: days * 60 * 60 * 24
end
