# Adapted from mix-erlang-tasks by Alexei Sholik:
#
# The MIT License (MIT)
#
#Copyright (c) 2015 Alexei Sholik <alcosholik@gmail.com>
#
#Permission is hereby granted, free of charge, to any person obtaining a copy
#of this software and associated documentation files (the "Software"), to deal
#in the Software without restriction, including without limitation the rights
#to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
#copies of the Software, and to permit persons to whom the Software is
#furnished to do so, subject to the following conditions:
#
#The above copyright notice and this permission notice shall be included in
#all copies or substantial portions of the Software.
#
#THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
#IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
#FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
#AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
#LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
#OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
#THE SOFTWARE.

defmodule Mix.Tasks.Ct do
  use Mix.Task

  @preferred_cli_env :ct

  @shortdoc "Run the project's Common Test suite"

  @moduledoc """
  # Command line options
    * `--log-dir` - change the output directory; default: _build/<ENV>/ct/logs
    * `--suites` - select the suites to run; default: all *_SUITE modules
    * `--cover` - run cover report
    * other options supported by `compile*` tasks
  """

  def run(args) do
    {opts, args, _errors} = OptionParser.parse(
                              args,
                              switches: [cover: :boolean,
                                         log_dir: :string],
                              aliases: [l: :log_dir, c: :cover])

    post_config = ct_post_config(Mix.Project.config)
    modify_project_config(post_config)

    ensure_compile
    Mix.Task.run "compile"

    logdir = Keyword.get(opts, :log_dir, "_build/#{Mix.env}/ct/log")
    File.mkdir_p!(logdir)

    ct_opts = [
      {:logdir, String.to_char_list(logdir)},
      {:auto_compile, false},
      {:config, 'test/test.config'},
      {:dir, String.to_char_list(test_path)}
    ]

    suites = case args do
               [] -> all_tests()
               _ -> args
             end

    if(Keyword.get(opts, :cover), do: cover_start())
    run_tests(suites, ct_opts)
    if(Keyword.get(opts, :cover), do: cover_analyse())
  end

  defp all_tests() do
    suitefiles = Path.join(test_path, "*_SUITE.beam") |> Path.wildcard
    for s <- suitefiles do
      Path.rootname(s) |> Path.basename
    end
  end

  defp test_path, do: Path.join(Mix.Project.app_path, "ebin")

  defp ct_post_config(existing_config) do
    [erlc_paths: existing_config[:erlc_paths] ++ ["test"],
     erlc_options: existing_config[:erlc_options] ++ [{:d, :TEST}]]
  end

  defp ensure_compile do
    # we have to reenable compile and all of its
    # child tasks (compile.erlang, compile.elixir, etc)
    Mix.Task.reenable("compile")
    Enum.each(compilers, &Mix.Task.reenable/1)
  end

  defp compilers do
    Mix.Task.all_modules
    |> Enum.map(&Mix.Task.task_name/1)
    |> Enum.filter(fn(t) -> match?("compile." <> _, t) end)
  end

  defp modify_project_config(post_config) do
    %{name: name, file: file} = Mix.Project.pop
    Mix.ProjectStack.post_config(post_config)
    Mix.Project.push name, file
  end

  defp run_tests([], _opts) do
    :ok
  end

  defp run_tests([suite | suites], opts) do
    copy_data_dir(suite)
    case :ct.run_test([{:suite, String.to_char_list(suite)} | opts]) do
      {_, 0, {_, _}} -> run_tests(suites, opts)
      _ -> Mix.raise("CT failure in " <> inspect(suite))
    end
  end

  defp copy_data_dir(suite) do
    data_dir_name = suite <> "_data"
    data_dir = Path.join("test", data_dir_name)
    dest_dir = Path.join(test_path, data_dir_name)

    case File.cp_r(data_dir, dest_dir) do
      {:ok, _} -> :ok
      {:error, :enoent, ^data_dir} -> :ok
      e -> Mix.raise("Error copying data dir for " <> inspect suite
                     <> ":" <> inspect e)
    end
  end

  defp cover_start() do
    :cover.compile_beam_directory(String.to_charlist(Mix.Project.compile_path))
  end

  defp cover_analyse() do
    dir = Mix.Project.config[:test_coverage][:output]
    File.mkdir_p(dir)
    :cover.analyse_to_file([:html, outdir: dir])
  end

end
