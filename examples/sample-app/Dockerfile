FROM mcr.microsoft.com/dotnet/sdk:10.0-azurelinux3.0 AS build

WORKDIR /src
COPY . .
RUN dotnet publish SampleApp.csproj --configuration Release --output /out /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/runtime:10.0-azurelinux3.0

WORKDIR /app
COPY --from=build /out .

USER 1654
ENTRYPOINT ["dotnet", "SampleApp.dll"]
