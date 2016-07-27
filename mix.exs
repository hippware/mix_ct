defmodule MixCt.Mixfile do
  use Mix.Project

  def project do
    [app: :mix_ct,
     version: "0.1.0",
     elixir: "~> 1.3",
     build_embedded: Mix.env == :prod,
     start_permanent: Mix.env == :prod,
     deps: deps]
  end

  defp deps do
    [{:cth_readable, "~> 1.2"}]
  end
end
