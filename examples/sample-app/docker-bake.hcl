variable "IMAGE_NAME" {
  default = "dotnet-k8s-sample"
}

variable "IMAGE_TAG" {
  default = "local"
}

variable "SOURCE_REVISION_ID" {
  default = "local"
}

variable "SYMBOLS_OUTPUT" {
  default = "./artifacts/sample-app/symbols"
}

group "default" {
  targets = ["runtime", "symbols"]
}

target "common" {
  context    = "./examples/sample-app"
  dockerfile = "Dockerfile"
  args = {
    SOURCE_REVISION_ID = "${SOURCE_REVISION_ID}"
  }
}

target "runtime" {
  inherits = ["common"]
  target   = "runtime"
  tags     = ["${IMAGE_NAME}:${IMAGE_TAG}"]
  output   = ["type=docker"]
}

target "symbols" {
  inherits = ["common"]
  target   = "symbols"
  output   = ["type=local,dest=${SYMBOLS_OUTPUT}"]
}
