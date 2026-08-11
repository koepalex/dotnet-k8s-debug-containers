FROM mcr.microsoft.com/dotnet/sdk:10.0-azurelinux3.0 AS publish

WORKDIR /src
COPY . .
ARG SOURCE_REVISION_ID=local
RUN printf '%s\n' \
      "{\"documents\":{\"/_/src/*\":\"https://raw.githubusercontent.com/koepalex/dotnet-k8s-debug-containers/${SOURCE_REVISION_ID}/examples/sample-app/*\"}}" \
      > /tmp/sourcelink.json \
    && dotnet publish SampleApp.csproj \
    --configuration Release \
    --output /out \
    /p:ContinuousIntegrationBuild=true \
    /p:EnableSourceLink=false \
    /p:SourceLink=/tmp/sourcelink.json \
    /p:SourceRevisionId="${SOURCE_REVISION_ID}" \
    /p:UseAppHost=false

FROM publish AS runtime-files

RUN mkdir /runtime \
    && cp -a /out/. /runtime/ \
    && find /runtime -type f -name '*.pdb' -delete

FROM scratch AS symbols

COPY --from=publish /out/*.pdb /

FROM mcr.microsoft.com/dotnet/runtime:10.0-azurelinux3.0 AS runtime

WORKDIR /app
COPY --from=runtime-files /runtime .

USER 1654
ENTRYPOINT ["dotnet", "SampleApp.dll"]
