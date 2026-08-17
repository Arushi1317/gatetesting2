public class BasicTests
{
    [Xunit.Fact]
    public void OnePlusOneEqualsTwo()
    {
        Assert.Equal(2, 1 + 1);
    }

    [Xunit.Fact]
    public void StringIsNotEmpty()
    {
        Assert.NotEmpty("HealthDemo");
    }
}
