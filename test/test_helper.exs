ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Textbin.Repo, :manual)

# Every API response is checked against its operation as tests run; after a
# full run, documented responses no test produced fail the suite.
TextbinWeb.ApiContract.start_coverage()
ExUnit.after_suite(fn _result -> TextbinWeb.ApiContract.report_coverage(System.argv()) end)
