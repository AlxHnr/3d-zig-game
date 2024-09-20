pub const Error = error{
    FailedToInitializeSDL2Window,
    FailedToLoadTextureFile,
    FailedToCompileAndLinkShader,
    FailedToRetrieveShaderLocation,
    FailedToDeserializeMapGeometry,
    OutOfAvailableUboBindingPoints,
};
