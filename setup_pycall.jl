ENV["PYTHON"] = raw"C:\Users\chahj\anaconda3\envs\lego_rvo2\python.exe"
using Pkg
Pkg.build("PyCall")
println("PYCALL_BUILD_DONE")
