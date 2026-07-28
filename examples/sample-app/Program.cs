Console.WriteLine($"SampleApp started with PID {Environment.ProcessId}.");

while (true)
{
    await Task.Delay(TimeSpan.FromSeconds(30));
    Console.WriteLine($"SampleApp heartbeat at {DateTimeOffset.UtcNow:O}.");
}
