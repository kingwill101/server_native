const c = @cImport({
    @cInclude("dart_api_dl.h");
});

export fn server_native_transport_version() c_int {
    return 1;
}
