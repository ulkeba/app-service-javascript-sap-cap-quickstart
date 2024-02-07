param location string = 'westeurope'

module m 'cosmos-psql-db.bicep' = [for i in range(1, 20): {
  name: 'm${i}'
  params: {
    location: location
    serverGroupName: 'server-${i}'
    administratorLoginPassword: 'the-password#123'
    version: '16'
  }
}]
