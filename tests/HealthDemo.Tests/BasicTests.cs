using System;
using System.Linq;
using HealthDemo;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Diagnostics.HealthChecks;
using Xunit;

namespace HealthDemo.Tests
{
    internal static class DbHelper
    {
        public static WeatherForecastDbContext Create(string name)
        {
            var options = new DbContextOptionsBuilder<WeatherForecastDbContext>()
                .UseInMemoryDatabase(name)
                .Options;
            return new WeatherForecastDbContext(options);
        }

        public static IServiceProvider CreateServiceProvider(string name)
        {
            var services = new ServiceCollection();
            services.AddDbContext<WeatherForecastDbContext>(opts =>
                opts.UseInMemoryDatabase(name));
            return services.BuildServiceProvider();
        }
    }

    public class WeatherForecastModelTests
    {
        private static int ExpectedF(int c) => 32 + (int)(c / 0.5556);

        [Fact] public void TempF_FromZeroC_Is32()              => Assert.Equal(32,             new WeatherForecast { TemperatureC = 0   }.TemperatureF);
        [Fact] public void TempF_From100C_MatchesFormula()     => Assert.Equal(ExpectedF(100), new WeatherForecast { TemperatureC = 100 }.TemperatureF);
        [Fact] public void TempF_FromMinus40C_MatchesFormula() => Assert.Equal(ExpectedF(-40), new WeatherForecast { TemperatureC = -40 }.TemperatureF);

        [Fact]
        public void AllProperties_SetAndGet()
        {
            var d  = new DateTime(2024, 6, 1);
            var wf = new WeatherForecast { Id = 7, Date = d, TemperatureC = 25, Summary = "Warm" };
            Assert.Equal(7,      wf.Id);
            Assert.Equal(d,      wf.Date);
            Assert.Equal(25,     wf.TemperatureC);
            Assert.Equal("Warm", wf.Summary);
        }

        [Theory]
        [InlineData(-20)]
        [InlineData(0)]
        [InlineData(20)]
        [InlineData(55)]
        public void TempF_Formula_IsCorrect(int c) =>
            Assert.Equal(ExpectedF(c), new WeatherForecast { TemperatureC = c }.TemperatureF);

        [Fact] public void Summary_DefaultsToNull() => Assert.Null(new WeatherForecast().Summary);
        [Fact] public void Id_DefaultsToZero()      => Assert.Equal(0, new WeatherForecast().Id);
    }

    public class WeatherForecastDbContextTests
    {
        [Fact]
        public void CanAdd_AndRetrieve()
        {
            using var ctx = DbHelper.Create("add_retrieve");
            ctx.WeatherForecasts.Add(new WeatherForecast { Date = DateTime.Now, TemperatureC = 20, Summary = "Mild" });
            ctx.SaveChanges();
            Assert.Equal("Mild", ctx.WeatherForecasts.First().Summary);
        }

        [Fact]
        public void CanAdd_Multiple()
        {
            using var ctx = DbHelper.Create("add_multiple");
            ctx.WeatherForecasts.AddRange(
                new WeatherForecast { Date = DateTime.Now,            TemperatureC = 10, Summary = "Cool" },
                new WeatherForecast { Date = DateTime.Now.AddDays(1), TemperatureC = 20, Summary = "Warm" },
                new WeatherForecast { Date = DateTime.Now.AddDays(2), TemperatureC = 30, Summary = "Hot"  }
            );
            ctx.SaveChanges();
            Assert.Equal(3, ctx.WeatherForecasts.Count());
        }

        [Fact]
        public void EmptyDb_HasNoForecasts()
        {
            using var ctx = DbHelper.Create("empty");
            Assert.Empty(ctx.WeatherForecasts);
        }

        [Fact]
        public void CanUpdate_Forecast()
        {
            using var ctx = DbHelper.Create("update");
            var wf = new WeatherForecast { Date = DateTime.Now, TemperatureC = 15, Summary = "Chilly" };
            ctx.WeatherForecasts.Add(wf);
            ctx.SaveChanges();
            wf.Summary = "Warm";
            ctx.SaveChanges();
            Assert.Equal("Warm", ctx.WeatherForecasts.First().Summary);
        }

        [Fact]
        public void CanDelete_Forecast()
        {
            using var ctx = DbHelper.Create("delete");
            var wf = new WeatherForecast { Date = DateTime.Now, TemperatureC = 15, Summary = "Chilly" };
            ctx.WeatherForecasts.Add(wf);
            ctx.SaveChanges();
            ctx.WeatherForecasts.Remove(wf);
            ctx.SaveChanges();
            Assert.Empty(ctx.WeatherForecasts);
        }
    }

    public class SeedDataTests
    {
        [Fact]
        public void Seeds_Exactly15Forecasts()
        {
            var sp = DbHelper.CreateServiceProvider("seed_count");
            SeedData.Initialize(sp);
            var ctx = sp.GetRequiredService<WeatherForecastDbContext>();
            Assert.Equal(15, ctx.WeatherForecasts.Count());
        }

        [Fact]
        public void Seeds_NoDuplicatesOnSecondCall()
        {
            var sp = DbHelper.CreateServiceProvider("seed_nodupe");
            SeedData.Initialize(sp);
            SeedData.Initialize(sp);
            var ctx = sp.GetRequiredService<WeatherForecastDbContext>();
            Assert.Equal(15, ctx.WeatherForecasts.Count());
        }

        [Fact]
        public void Seeds_AllHaveValidDates()
        {
            var sp = DbHelper.CreateServiceProvider("seed_dates");
            SeedData.Initialize(sp);
            var ctx = sp.GetRequiredService<WeatherForecastDbContext>();
            Assert.All(ctx.WeatherForecasts.ToList(), f => Assert.True(f.Date > DateTime.MinValue));
        }

        [Fact]
        public void Seeds_AllHaveNonEmptySummary()
        {
            var sp = DbHelper.CreateServiceProvider("seed_summary");
            SeedData.Initialize(sp);
            var ctx = sp.GetRequiredService<WeatherForecastDbContext>();
            Assert.All(ctx.WeatherForecasts.ToList(), f => Assert.False(string.IsNullOrWhiteSpace(f.Summary)));
        }

        [Fact]
        public void Seeds_TemperaturesInRange()
        {
            var sp = DbHelper.CreateServiceProvider("seed_temps");
            SeedData.Initialize(sp);
            var ctx = sp.GetRequiredService<WeatherForecastDbContext>();
            Assert.All(ctx.WeatherForecasts.ToList(), f =>
            {
                Assert.True(f.TemperatureC >= -20);
                Assert.True(f.TemperatureC <= 55);
            });
        }

        [Fact]
        public void Seeds_AllDatesInFuture()
        {
            var sp = DbHelper.CreateServiceProvider("seed_future");
            SeedData.Initialize(sp);
            var ctx = sp.GetRequiredService<WeatherForecastDbContext>();
            Assert.All(ctx.WeatherForecasts.ToList(), f => Assert.True(f.Date > DateTime.Now.AddMinutes(-1)));
        }
    }

    public class HealthChecksRegistrationTests
    {
        [Fact]
        public void HealthCheckService_CanBeRegistered()
        {
            var services = new ServiceCollection();
            services.AddLogging();
            services.AddHealthChecks();
            Assert.NotNull(services.BuildServiceProvider().GetService<HealthCheckService>());
        }

        [Fact]
        public void MultipleHealthChecks_CanBeRegistered()
        {
            var services = new ServiceCollection();
            services.AddLogging();
            services.AddHealthChecks()
                .AddCheck("check1", () => HealthCheckResult.Healthy())
                .AddCheck("check2", () => HealthCheckResult.Healthy());
            Assert.NotNull(services.BuildServiceProvider().GetService<HealthCheckService>());
        }
    }
}
